package com.familyshield.agent.enforcement

/** What the service does about a blocked app's media session. The tokens themselves stay in the service. */
sealed interface MediaAction {
    /** Keep the media-session token that came with [pkg]'s notification. */
    data class Store(val pkg: String) : MediaAction

    /** Drop [pkg]'s token: the app is no longer blocked. */
    data class Forget(val pkg: String) : MediaAction

    /** Pause [pkg]'s own session through its `MediaController`. Never a global media key. */
    data class Pause(val pkg: String) : MediaAction
}

/**
 * Issue #444 C4: a blocked app plays no audio, whether it is started from its window, the shade, a headset
 * button or the lock screen.
 *
 * The first design paired a playback start with a media post inside 2 s and sent a global pause key. Karim's
 * Flip4 run (30 Oct) failed it both ways: a resume from the shade or the lock screen does **not** re-post the
 * notification, so nothing paired; and a global key goes to whoever holds the media buttons, which can be an
 * allowed player started at the same moment (C4-4).
 *
 * The accessibility parcel of a media notification carries `EXTRA_MEDIA_SESSION` (the Flip4 logged
 * `token=true`). So, with no NotificationListener:
 *
 * - a **blocked** app's media post stores its token, replacing any older one ([MediaAction.Store]);
 * - whenever playback might have started (a media post, the playback callback, the session's own callback,
 *   or the block screen going up), every stored token whose app is still blocked **and** whose session is
 *   playing is paused through that session only ([MediaAction.Pause]);
 * - a token whose app is no longer blocked is dropped and never paused ([MediaAction.Forget]).
 *
 * An allowed player is never touched: its token is never stored. Pure; the service answers `isBlocked` and
 * `isPlaying` (its controller's `playbackState == STATE_PLAYING`).
 */
class MediaBlockPolicy {
    private val stored = LinkedHashSet<String>()

    /** A media notification from [pkg]. [hasToken]: its parcel carried `EXTRA_MEDIA_SESSION`. */
    fun onMediaNotification(
        pkg: String,
        blocked: Boolean,
        hasToken: Boolean,
        isPlaying: (String) -> Boolean,
    ): List<MediaAction> {
        if (!blocked) return if (stored.remove(pkg)) listOf(MediaAction.Forget(pkg)) else emptyList()
        val out = ArrayList<MediaAction>()
        if (hasToken) {
            stored += pkg
            out += MediaAction.Store(pkg)
        }
        if (pkg in stored && isPlaying(pkg)) out += MediaAction.Pause(pkg)
        return out
    }

    /** Media playback started somewhere (`AudioPlaybackCallback`), or a stored session reported PLAYING. */
    fun onPlaybackMaybeStarted(isBlocked: (String) -> Boolean, isPlaying: (String) -> Boolean): List<MediaAction> {
        val out = ArrayList<MediaAction>()
        for (pkg in stored.toList()) {
            when {
                !isBlocked(pkg) -> {
                    stored.remove(pkg)
                    out += MediaAction.Forget(pkg)
                }
                isPlaying(pkg) -> out += MediaAction.Pause(pkg)
            }
        }
        return out
    }

    /** The block screen was raised for [pkg]: if its stored session is playing, pause it. */
    fun onRaise(pkg: String, isPlaying: (String) -> Boolean): List<MediaAction> =
        if (pkg in stored && isPlaying(pkg)) listOf(MediaAction.Pause(pkg)) else emptyList()
}
