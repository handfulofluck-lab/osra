package com.familyshield.agent

import com.familyshield.agent.enforcement.MediaAction
import com.familyshield.agent.enforcement.MediaBlockPolicy
import org.junit.Assert.assertEquals
import org.junit.Test

/**
 * Issue #444 C4, after the Flip4 run of 30 Oct and the #457 review: a resume from the shade or the lock screen
 * posts nothing new, a global pause key can hit an allowed player, and the common case is a block applied to
 * an app that is already playing. Every app's token is kept; only a blocked app's own playing session is paused.
 */
class MediaBlockPolicyTest {

    private val youtube = "com.google.android.youtube"
    private val vlc = "org.videolan.vlc"
    private var blocked = setOf(youtube)
    private var playing = emptySet<String>()
    private val isBlocked: (String) -> Boolean = { it in blocked }
    private val isPlaying: (String) -> Boolean = { it in playing }

    private fun MediaBlockPolicy.post(pkg: String, hasToken: Boolean = true) =
        onMediaNotification(pkg, hasToken, isBlocked, isPlaying)

    private fun MediaBlockPolicy.sweep() = onPlaybackMaybeStarted(isBlocked, isPlaying)

    @Test
    fun `launch - a blocked app's first media post stores its session and pauses it if it plays`() {
        val p = MediaBlockPolicy()
        playing = setOf(youtube)
        assertEquals(listOf(MediaAction.Store(youtube), MediaAction.Pause(youtube)), p.post(youtube))
    }

    @Test
    fun `R1 - resumed from the shade or the lock screen with no new post, it is paused, every time`() {
        val p = MediaBlockPolicy()
        p.post(youtube) // paused at the time of the post
        playing = setOf(youtube)
        assertEquals(listOf(MediaAction.Pause(youtube)), p.sweep())
        assertEquals("the token is kept for the next resume", listOf(MediaAction.Pause(youtube)), p.sweep())
    }

    @Test
    fun `R5 - posted while allowed, then blocked, then resumed from the shade with no new post - paused`() {
        val p = MediaBlockPolicy()
        blocked = emptySet()
        assertEquals("an allowed app's token is stored too", listOf(MediaAction.Store(youtube)), p.post(youtube))
        blocked = setOf(youtube)
        playing = setOf(youtube)
        assertEquals(listOf(MediaAction.Pause(youtube)), p.sweep())
    }

    @Test
    fun `R6 - posted while allowed and playing, then a rule sync blocks it - paused at once`() {
        val p = MediaBlockPolicy()
        blocked = emptySet()
        playing = setOf(youtube)
        assertEquals("allowed and playing: not paused", listOf(MediaAction.Store(youtube)), p.post(youtube))
        blocked = setOf(youtube) // the rule sync's own sweep
        assertEquals(listOf(MediaAction.Pause(youtube)), p.sweep())
    }

    @Test
    fun `R2 - a stored allowed player is never paused while it stays allowed`() {
        val p = MediaBlockPolicy()
        p.post(youtube)
        assertEquals(listOf(MediaAction.Store(vlc)), p.post(vlc))
        playing = setOf(vlc)
        assertEquals(emptyList<MediaAction>(), p.sweep())
        assertEquals(emptyList<MediaAction>(), p.post(vlc, hasToken = false))
    }

    @Test
    fun `R3 - an app that is unblocked is not paused, and is paused again once re-blocked`() {
        val p = MediaBlockPolicy()
        p.post(youtube)
        blocked = emptySet()
        playing = setOf(youtube)
        assertEquals(emptyList<MediaAction>(), p.sweep())
        blocked = setOf(youtube)
        assertEquals(listOf(MediaAction.Pause(youtube)), p.sweep())
    }

    @Test
    fun `a destroyed session's token is gone`() {
        val p = MediaBlockPolicy()
        p.post(youtube)
        p.onSessionDestroyed(youtube)
        playing = setOf(youtube)
        assertEquals(emptyList<MediaAction>(), p.sweep())
        assertEquals(emptyList<MediaAction>(), p.onRaise(youtube, isPlaying))
    }

    @Test
    fun `a stored session that is not playing is not paused`() {
        val p = MediaBlockPolicy()
        p.post(youtube)
        assertEquals(emptyList<MediaAction>(), p.sweep())
        assertEquals(emptyList<MediaAction>(), p.onRaise(youtube, isPlaying))
    }

    @Test
    fun `the block screen going up pauses the blocked app's playing session`() {
        val p = MediaBlockPolicy()
        p.post(youtube)
        playing = setOf(youtube)
        assertEquals(listOf(MediaAction.Pause(youtube)), p.onRaise(youtube, isPlaying))
    }

    @Test
    fun `a post without a token stores nothing and pauses nothing`() {
        val p = MediaBlockPolicy()
        playing = setOf(youtube)
        assertEquals(emptyList<MediaAction>(), p.post(youtube, hasToken = false))
        assertEquals(emptyList<MediaAction>(), p.sweep())
    }

    @Test
    fun `R7 - a resume that leaves the media count unchanged is still swept and paused`() {
        val p = MediaBlockPolicy()
        p.post(youtube)
        assertEquals("paused, one player in the list", emptyList<MediaAction>(), p.onPlaybackConfigChanged(1, isBlocked, isPlaying))
        playing = setOf(youtube)
        assertEquals(
            "same count, now playing: paused",
            listOf(MediaAction.Pause(youtube)),
            p.onPlaybackConfigChanged(1, isBlocked, isPlaying),
        )
    }
}
