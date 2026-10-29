package com.familyshield.agent

import com.familyshield.agent.enforcement.MediaAction
import com.familyshield.agent.enforcement.MediaBlockPolicy
import org.junit.Assert.assertEquals
import org.junit.Test

/** Issue #444 C4: Karim's M5 — Play in the shade resumed a blocked YouTube behind the block screen. */
class MediaBlockPolicyTest {

    private val youtube = "com.google.android.youtube"
    private val spotify = "com.spotify.music"

    @Test
    fun `focus is requested when the block screen goes up`() {
        assertEquals(listOf(MediaAction.RequestFocus), MediaBlockPolicy().onRaise())
    }

    @Test
    fun `M5 - Play in the shade for a blocked app gets focus taken back and one pause`() {
        val p = MediaBlockPolicy()
        p.onRaise()
        assertEquals(emptyList<MediaAction>(), p.onMediaNotification(youtube, blocked = true, nowMs = 10_000L))
        assertEquals(
            listOf(MediaAction.RequestFocus, MediaAction.SendPause),
            p.onPlaybackStarted(nowMs = 10_400L),
        )
    }

    @Test
    fun `an allowed app's playback is never paused, and focus is given back to it`() {
        val p = MediaBlockPolicy()
        p.onRaise()
        assertEquals(listOf(MediaAction.AbandonFocus), p.onMediaNotification(spotify, blocked = false, nowMs = 0L))
        assertEquals(emptyList<MediaAction>(), p.onPlaybackStarted(nowMs = 300L))
    }

    @Test
    fun `playback with no matching media post within two seconds does nothing`() {
        val p = MediaBlockPolicy()
        assertEquals("no poster at all", emptyList<MediaAction>(), p.onPlaybackStarted(nowMs = 0L))
        p.onMediaNotification(youtube, blocked = true, nowMs = 0L)
        assertEquals("a stale blocked post", emptyList<MediaAction>(), p.onPlaybackStarted(nowMs = 2_001L))
    }

    @Test
    fun `the last media poster decides - an allowed post after the blocked one wins`() {
        val p = MediaBlockPolicy()
        p.onMediaNotification(youtube, blocked = true, nowMs = 0L)
        p.onMediaNotification(spotify, blocked = false, nowMs = 100L)
        assertEquals(emptyList<MediaAction>(), p.onPlaybackStarted(nowMs = 200L))
    }

    @Test
    fun `B1 - playback first, then the blocked app's Playing update within two seconds, is paused`() {
        val p = MediaBlockPolicy()
        p.onMediaNotification(youtube, blocked = true, nowMs = 0L) // the old Paused post, minutes ago
        assertEquals(emptyList<MediaAction>(), p.onPlaybackStarted(nowMs = 10_000L))
        assertEquals(
            listOf(MediaAction.RequestFocus, MediaAction.SendPause),
            p.onMediaNotification(youtube, blocked = true, nowMs = 10_300L),
        )
    }

    @Test
    fun `B1 - a blocked app's post more than two seconds after playback does nothing`() {
        val p = MediaBlockPolicy()
        p.onPlaybackStarted(nowMs = 0L)
        assertEquals(emptyList<MediaAction>(), p.onMediaNotification(youtube, blocked = true, nowMs = 2_500L))
    }
}
