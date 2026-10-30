package com.familyshield.agent

import com.familyshield.agent.enforcement.MediaAction
import com.familyshield.agent.enforcement.MediaBlockPolicy
import org.junit.Assert.assertEquals
import org.junit.Test

/**
 * Issue #444 C4, after the Flip4 run of 30 Oct: a resume from the shade or the lock screen posts nothing new,
 * and a global pause key can hit an allowed player. Pauses go only to a blocked app's own stored session.
 */
class MediaBlockPolicyTest {

    private val youtube = "com.google.android.youtube"
    private val vlc = "org.videolan.vlc"
    private var blocked = setOf(youtube)
    private var playing = emptySet<String>()
    private val isBlocked: (String) -> Boolean = { it in blocked }
    private val isPlaying: (String) -> Boolean = { it in playing }

    private fun MediaBlockPolicy.post(pkg: String, hasToken: Boolean = true) =
        onMediaNotification(pkg, pkg in blocked, hasToken, isPlaying)

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
        assertEquals(listOf(MediaAction.Pause(youtube)), p.onPlaybackMaybeStarted(isBlocked, isPlaying))
        assertEquals("the token is kept for the next resume", listOf(MediaAction.Pause(youtube)), p.onPlaybackMaybeStarted(isBlocked, isPlaying))
    }

    @Test
    fun `R2 - an allowed player is never touched, even right after the blocked app's post`() {
        val p = MediaBlockPolicy()
        p.post(youtube)
        assertEquals(emptyList<MediaAction>(), p.post(vlc))
        playing = setOf(vlc)
        assertEquals(emptyList<MediaAction>(), p.onPlaybackMaybeStarted(isBlocked, isPlaying))
    }

    @Test
    fun `R3 - a token whose app is unblocked is dropped and never paused`() {
        val p = MediaBlockPolicy()
        p.post(youtube)
        blocked = emptySet()
        playing = setOf(youtube)
        assertEquals(listOf(MediaAction.Forget(youtube)), p.onPlaybackMaybeStarted(isBlocked, isPlaying))
        assertEquals("gone for good", emptyList<MediaAction>(), p.onPlaybackMaybeStarted(isBlocked, isPlaying))
    }

    @Test
    fun `an unblocked app's own new post also drops its token`() {
        val p = MediaBlockPolicy()
        p.post(youtube)
        blocked = emptySet()
        assertEquals(listOf(MediaAction.Forget(youtube)), p.post(youtube))
    }

    @Test
    fun `a stored session that is not playing is not paused`() {
        val p = MediaBlockPolicy()
        p.post(youtube)
        assertEquals(emptyList<MediaAction>(), p.onPlaybackMaybeStarted(isBlocked, isPlaying))
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
        assertEquals(emptyList<MediaAction>(), p.onPlaybackMaybeStarted(isBlocked, isPlaying))
    }
}
