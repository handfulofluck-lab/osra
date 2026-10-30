package com.familyshield.agent.enforcement

/** What the service does about an app's media session. The tokens themselves stay in the service. */
sealed interface MediaAction {
    /** Keep the media-session token that came with [pkg]'s notification (replacing an older one). */
    data class Store(val pkg: String) : MediaAction

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
 * - **every** app's media post stores its token, replacing any older one ([MediaAction.Store]): the usual
 *   case is a child already watching an allowed app when the parent blocks it (#457 review, R5);
 * - whenever playback might have started (a media post, the playback callback, the session's own callback,
 *   the block screen going up, or a rule sync), each stored session whose app is blocked **now** and which is
 *   playing is paused through that session only ([MediaAction.Pause]);
 * - a token goes only when its session is destroyed ([onSessionDestroyed]); an app that is unblocked keeps
 *   its token, because it may be blocked again.
 *
 * An allowed player is never touched: the `isBlocked` check at pause time guarantees it. Pure; the service
 * answers `isBlocked` and `isPlaying` (its controller's `playbackState == STATE_PLAYING`).
 */
class MediaBlockPolicy {
    private val stored = LinkedHashSet<String>()

    /** A media notification from [pkg]. [hasToken]: its parcel carried `EXTRA_MEDIA_SESSION`. */
    fun onMediaNotification(
        pkg: String,
        hasToken: Boolean,
        isBlocked: (String) -> Boolean,
        isPlaying: (String) -> Boolean,
    ): List<MediaAction> {
        val out = ArrayList<MediaAction>()
        if (hasToken) {
            stored += pkg
            out += MediaAction.Store(pkg)
        }
        if (pkg in stored && isBlocked(pkg) && isPlaying(pkg)) out += MediaAction.Pause(pkg)
        return out
    }

    /**
     * Playback may have started, or the rules changed: a new media player (`AudioPlaybackCallback`), a stored
     * session reporting PLAYING, or a rule sync that may have just blocked an app that is playing.
     */
    fun onPlaybackMaybeStarted(isBlocked: (String) -> Boolean, isPlaying: (String) -> Boolean): List<MediaAction> =
        stored.filter { isBlocked(it) && isPlaying(it) }.map { MediaAction.Pause(it) }

    /**
     * Every `AudioPlaybackCallback.onPlaybackConfigChanged` (#457 review, R7): the sweep runs each time, not
     * only when the number of media players rises. On the Flip4 a paused player stays in the list, so a resume
     * from the shade or the lock screen leaves the count where it was. [mediaCount] is kept for the debug log.
     */
    @Suppress("UNUSED_PARAMETER")
    fun onPlaybackConfigChanged(
        mediaCount: Int,
        isBlocked: (String) -> Boolean,
        isPlaying: (String) -> Boolean,
    ): List<MediaAction> = onPlaybackMaybeStarted(isBlocked, isPlaying)

    /** How many sessions are stored, for the debug log. */
    val storedCount: Int get() = stored.size

    /** The stored packages, for the debug log. */
    fun storedPackages(): List<String> = stored.toList()

    /** The block screen was raised for [pkg]: if its stored session is playing, pause it. */
    fun onRaise(pkg: String, isPlaying: (String) -> Boolean): List<MediaAction> =
        if (pkg in stored && isPlaying(pkg)) listOf(MediaAction.Pause(pkg)) else emptyList()

    /** The session behind [pkg]'s token is gone (or the package was removed). */
    fun onSessionDestroyed(pkg: String) {
        stored.remove(pkg)
    }
}
