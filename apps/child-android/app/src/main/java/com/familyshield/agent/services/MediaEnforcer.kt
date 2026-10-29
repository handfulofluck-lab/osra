package com.familyshield.agent.services

import android.accessibilityservice.AccessibilityService
import android.app.Notification
import android.media.AudioAttributes
import android.media.AudioFocusRequest
import android.media.AudioManager
import android.media.AudioPlaybackConfiguration
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.util.Log
import android.view.KeyEvent
import android.view.accessibility.AccessibilityEvent
import com.familyshield.agent.enforcement.MediaAction
import com.familyshield.agent.enforcement.MediaBlockPolicy

/**
 * Issue #444 C4: the Android side of [MediaBlockPolicy]. It notices media notifications from accessibility
 * events (category and template only, never the title, artist or artwork), counts active media-usage players
 * through `AudioPlaybackCallback`, and applies focus and the pause key. No NotificationListener, so the Play
 * build gets it too.
 */
class MediaEnforcer(
    private val service: AccessibilityService,
    private val isBlocked: (String) -> Boolean,
) {
    private val policy = MediaBlockPolicy()
    private val audio = service.getSystemService(AudioManager::class.java)
    private var activeMedia = 0

    private val focusRequest = AudioFocusRequest.Builder(AudioManager.AUDIOFOCUS_GAIN)
        .setAudioAttributes(
            AudioAttributes.Builder()
                .setUsage(AudioAttributes.USAGE_MEDIA)
                .setContentType(AudioAttributes.CONTENT_TYPE_MUSIC)
                .build(),
        )
        .setOnAudioFocusChangeListener { }
        .build()

    private val playback = object : AudioManager.AudioPlaybackCallback() {
        override fun onPlaybackConfigChanged(configs: MutableList<AudioPlaybackConfiguration>?) {
            val media = configs.orEmpty().count { it.audioAttributes.usage == AudioAttributes.USAGE_MEDIA }
            val started = media > activeMedia
            activeMedia = media
            // #444 C4 review B2: does a resume raise the count on the Flip4? Counts only, no packages.
            Log.d(TAG, "media=$media started=$started")
            if (started) apply(policy.onPlaybackStarted(SystemClock.elapsedRealtime()))
        }
    }

    fun onConnected() {
        runCatching { audio?.registerAudioPlaybackCallback(playback, Handler(Looper.getMainLooper())) }
            .onFailure { Log.w(TAG, "no playback callback", it) }
    }

    fun onDestroy() {
        runCatching { audio?.unregisterAudioPlaybackCallback(playback) }
        runCatching { audio?.abandonAudioFocusRequest(focusRequest) }
    }

    /** The block or time-limit screen was raised. */
    fun onRaise() = apply(policy.onRaise())

    /** A `TYPE_NOTIFICATION_STATE_CHANGED` event. */
    fun onNotification(event: AccessibilityEvent) {
        val pkg = event.packageName?.toString() ?: return
        if (pkg == service.packageName) return
        val notification = runCatching { event.parcelableData as? Notification }.getOrNull() ?: return
        val template = notification.extras?.getString(Notification.EXTRA_TEMPLATE).orEmpty()
        val isMedia = notification.category == Notification.CATEGORY_TRANSPORT || template.contains("MediaStyle")
        if (!isMedia) return
        // #444 C4 review: does the media-session token reach the accessibility event? A boolean only. If it does,
        // a MediaController on the blocked app's own session is the targeted fallback should C4-4 fail.
        Log.d(TAG, "token=${notification.extras?.containsKey(Notification.EXTRA_MEDIA_SESSION)}")
        // The policy's windows use the monotonic clock: a wall-clock change must not open or close them.
        apply(policy.onMediaNotification(pkg, isBlocked(pkg), SystemClock.elapsedRealtime()))
    }

    private fun apply(actions: List<MediaAction>) {
        val am = audio ?: return
        for (action in actions) {
            when (action) {
                MediaAction.RequestFocus -> runCatching { am.requestAudioFocus(focusRequest) }
                MediaAction.AbandonFocus -> runCatching { am.abandonAudioFocusRequest(focusRequest) }
                MediaAction.SendPause -> runCatching {
                    val now = SystemClock.uptimeMillis()
                    am.dispatchMediaKeyEvent(KeyEvent(now, now, KeyEvent.ACTION_DOWN, KeyEvent.KEYCODE_MEDIA_PAUSE, 0))
                    am.dispatchMediaKeyEvent(KeyEvent(now, now, KeyEvent.ACTION_UP, KeyEvent.KEYCODE_MEDIA_PAUSE, 0))
                    Log.i(TAG, "pause sent: a blocked app's media started (#444 C4)")
                }
            }
        }
    }

    private companion object {
        const val TAG = "MediaEnforcer"
    }
}
