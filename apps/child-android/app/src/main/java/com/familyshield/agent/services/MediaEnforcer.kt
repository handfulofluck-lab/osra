package com.familyshield.agent.services

import android.accessibilityservice.AccessibilityService
import android.app.Notification
import android.media.AudioAttributes
import android.media.AudioManager
import android.media.AudioPlaybackConfiguration
import android.media.session.MediaController
import android.media.session.MediaSession
import android.media.session.PlaybackState
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.util.Log
import android.view.accessibility.AccessibilityEvent
import com.familyshield.agent.enforcement.MediaAction
import com.familyshield.agent.enforcement.MediaBlockPolicy

/**
 * Issue #444 C4: the Android side of [MediaBlockPolicy]. From a blocked app's media notification (category
 * or template, and the `EXTRA_MEDIA_SESSION` token; never the title, artist or artwork) it keeps one
 * [MediaController] per blocked package, and pauses **that** session when it plays. A resume from the shade or
 * the lock screen is seen two ways, because on the Flip4 it posts nothing new: the session's own callback
 * reports PLAYING, and `AudioPlaybackCallback` reports a new media player. No audio focus and no global media
 * key: an allowed player is never touched (#444, C4-4). No NotificationListener, so the Play build has it too.
 */
class MediaEnforcer(
    private val service: AccessibilityService,
    private val isBlocked: (String) -> Boolean,
) {
    private val policy = MediaBlockPolicy()
    private val audio = service.getSystemService(AudioManager::class.java)
    private val main = Handler(Looper.getMainLooper())
    private val controllers = HashMap<String, MediaController>()
    private val callbacks = HashMap<String, MediaController.Callback>()
    private var activeMedia = 0

    private val playback = object : AudioManager.AudioPlaybackCallback() {
        override fun onPlaybackConfigChanged(configs: MutableList<AudioPlaybackConfiguration>?) {
            val media = configs.orEmpty().count { it.audioAttributes.usage == AudioAttributes.USAGE_MEDIA }
            val started = media > activeMedia
            activeMedia = media
            if (started) apply(policy.onPlaybackMaybeStarted(isBlocked, ::isPlaying))
        }
    }

    fun onConnected() {
        runCatching { audio?.registerAudioPlaybackCallback(playback, main) }
            .onFailure { Log.w(TAG, "no playback callback", it) }
    }

    fun onDestroy() {
        runCatching { audio?.unregisterAudioPlaybackCallback(playback) }
        controllers.keys.toList().forEach(::forget)
    }

    /** The block or time-limit screen was raised for [pkg]. */
    fun onRaise(pkg: String) = apply(policy.onRaise(pkg, ::isPlaying))

    /** A `TYPE_NOTIFICATION_STATE_CHANGED` event. */
    fun onNotification(event: AccessibilityEvent) {
        val pkg = event.packageName?.toString() ?: return
        if (pkg == service.packageName) return
        val notification = runCatching { event.parcelableData as? Notification }.getOrNull() ?: return
        val template = notification.extras?.getString(Notification.EXTRA_TEMPLATE).orEmpty()
        val isMedia = notification.category == Notification.CATEGORY_TRANSPORT || template.contains("MediaStyle")
        if (!isMedia) return
        val token = notification.extras?.token()
        val blocked = isBlocked(pkg)
        // The policy's Store condition, applied first so a Pause in the same answer reaches the new session.
        if (blocked && token != null) store(pkg, token)
        apply(policy.onMediaNotification(pkg, blocked, hasToken = token != null, ::isPlaying))
    }

    private fun apply(actions: List<MediaAction>) {
        for (action in actions) {
            when (action) {
                is MediaAction.Store -> Unit // stored in onNotification, where the token is in hand
                is MediaAction.Forget -> forget(action.pkg)
                is MediaAction.Pause -> runCatching { controllers[action.pkg]?.transportControls?.pause() }
                    .onSuccess { Log.i(TAG, "paused a blocked app's media session (#444 C4)") }
                    .onFailure { Log.w(TAG, "pause failed", it) }
            }
        }
    }

    private fun isPlaying(pkg: String): Boolean =
        runCatching { controllers[pkg]?.playbackState?.state == PlaybackState.STATE_PLAYING }.getOrDefault(false)

    private fun store(pkg: String, token: MediaSession.Token) {
        forget(pkg)
        val controller = runCatching { MediaController(service, token) }.getOrNull() ?: return
        val callback = object : MediaController.Callback() {
            override fun onPlaybackStateChanged(state: PlaybackState?) {
                if (state?.state == PlaybackState.STATE_PLAYING) apply(policy.onPlaybackMaybeStarted(isBlocked, ::isPlaying))
            }

            override fun onSessionDestroyed() {
                main.post { forget(pkg) }
            }
        }
        runCatching { controller.registerCallback(callback, main) }
        controllers[pkg] = controller
        callbacks[pkg] = callback
    }

    private fun forget(pkg: String) {
        val controller = controllers.remove(pkg) ?: return
        callbacks.remove(pkg)?.let { runCatching { controller.unregisterCallback(it) } }
    }

    @Suppress("DEPRECATION")
    private fun android.os.Bundle.token(): MediaSession.Token? =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            getParcelable(Notification.EXTRA_MEDIA_SESSION, MediaSession.Token::class.java)
        } else {
            getParcelable(Notification.EXTRA_MEDIA_SESSION) as? MediaSession.Token
        }

    private companion object {
        const val TAG = "MediaEnforcer"
    }
}
