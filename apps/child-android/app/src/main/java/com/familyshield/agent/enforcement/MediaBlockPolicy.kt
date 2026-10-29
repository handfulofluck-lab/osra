package com.familyshield.agent.enforcement

/** What the service does about media audio. */
sealed interface MediaAction {
    /** Take `AUDIOFOCUS_GAIN` with media usage: a well-behaved player pauses on the loss. */
    data object RequestFocus : MediaAction

    /** Give it back, so an allowed app is not left without audio. */
    data object AbandonFocus : MediaAction

    /** One `KEYCODE_MEDIA_PAUSE` through `AudioManager.dispatchMediaKeyEvent`. */
    data object SendPause : MediaAction
}

/**
 * Issue #444 C4 (Karim on the Flip4, 29 Oct 15:08Z): with YouTube blocked and the block screen up, Play on
 * YouTube's media notification in the shade resumed the audio behind the block screen. Requirement: a blocked
 * app plays no audio, whether started from its window, the shade, a headset button or the lock screen.
 *
 * The Play build has no NotificationListener, so the agent cannot read media sessions. It knows two things:
 * which package last posted a media notification (`CATEGORY_TRANSPORT` or a `MediaStyle` template, from
 * accessibility notification events), and when media-usage playback starts (`AudioPlaybackCallback`, which
 * does not name the package for a normal app). Claude's mechanism (#444, 15:12Z):
 *
 * 1. When the block screen goes up for a package, take audio focus.
 * 2. When media playback starts within [windowMs] of a media post by a **blocked** package, take focus again
 *    and send one pause.
 * 3. Never when the last media poster is allowed, so a child's allowed music app keeps playing.
 * 4. Give focus back once the last media poster is an allowed package.
 *
 * Pure, with the clock as a parameter.
 */
class MediaBlockPolicy(private val windowMs: Long = DEFAULT_WINDOW_MS) {
    private data class Poster(val pkg: String, val blocked: Boolean, val atMs: Long)

    private var lastMediaPoster: Poster? = null
    private var holdingFocus = false

    /** The block (or time-limit) screen was raised for a package. */
    fun onRaise(): List<MediaAction> = requestFocus()

    /** A media notification was posted or updated (Play pressed in the shade updates it). */
    fun onMediaNotification(pkg: String, blocked: Boolean, nowMs: Long): List<MediaAction> {
        lastMediaPoster = Poster(pkg, blocked, nowMs)
        if (!blocked && holdingFocus) {
            holdingFocus = false
            return listOf(MediaAction.AbandonFocus)
        }
        return emptyList()
    }

    /** Media-usage playback became active (the count of active media players went up). */
    fun onPlaybackStarted(nowMs: Long): List<MediaAction> {
        val poster = lastMediaPoster ?: return emptyList()
        if (!poster.blocked || nowMs - poster.atMs !in 0..windowMs) return emptyList()
        holdingFocus = false // a new request, whatever we held: the player may have just taken it back
        return requestFocus() + MediaAction.SendPause
    }

    private fun requestFocus(): List<MediaAction> {
        holdingFocus = true
        return listOf(MediaAction.RequestFocus)
    }

    companion object {
        /** "Media-usage playback becoming active within 2 s" of the blocked app's media post (Claude, #444). */
        const val DEFAULT_WINDOW_MS: Long = 2_000L
    }
}
