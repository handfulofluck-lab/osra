package com.familyshield.agent

import com.familyshield.agent.enforcement.BlockRaise
import com.familyshield.agent.enforcement.BlockRaisePolicy
import com.familyshield.agent.enforcement.PipCoverAction
import com.familyshield.agent.enforcement.PipCoverDecision
import com.familyshield.agent.enforcement.WindowBounds
import com.familyshield.agent.enforcement.WindowLayout
import com.familyshield.agent.security.TamperAlertDedupe
import com.familyshield.agent.security.TamperAlertWorker
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Issue #175 (reopened after #194). Two failures the hardware run showed:
 * - a Meet call screen came back over the block screen, and the retry budget then gave up for good;
 * - a blocked video in picture-in-picture stayed above the block screen, and nobody was told.
 */
class BlockRaisePolicyTest {

    private val meet = "com.google.android.apps.tachyon"
    private val youtube = "com.google.android.youtube"

    @Test
    fun `normal layout - the app that keeps coming back is sent Home and covered every time, a second apart`() {
        val policy = BlockRaisePolicy()
        val raises = (0 until 10).map { i -> policy.decide(meet, WindowLayout.NORMAL, blockedIsActive = true, nowMs = 10_000L + i * 1_000L) }

        assertTrue("never exhausted in the normal layout", raises.all { it.raise && it.goHome })
        assertTrue("never reported as a bypass", raises.none { it.reportBypass })
    }

    @Test
    fun `normal layout - events inside the second do not start another screen`() {
        val policy = BlockRaisePolicy()
        assertTrue(policy.decide(meet, WindowLayout.NORMAL, true, 10_000L).raise)
        assertEquals(BlockRaise.NOTHING, policy.decide(meet, WindowLayout.NORMAL, true, 10_100L))
        assertEquals(BlockRaise.NOTHING, policy.decide(meet, WindowLayout.NORMAL, true, 10_999L))
        assertTrue(policy.decide(meet, WindowLayout.NORMAL, true, 11_000L).raise)
    }

    @Test
    fun `normal layout - a backwards clock does not suppress raises`() {
        val policy = BlockRaisePolicy()
        assertTrue(policy.decide(meet, WindowLayout.NORMAL, true, 10_000L).raise)
        assertTrue(policy.decide(meet, WindowLayout.NORMAL, true, 5_000L).raise)
    }

    @Test
    fun `normal layout - Home is not sent when our own screen is already in front`() {
        val step = BlockRaisePolicy().decide(meet, WindowLayout.NORMAL, blockedIsActive = false, nowMs = 1_000L)
        assertTrue(step.raise)
        assertFalse(step.goHome)
    }

    @Test
    fun `PiP - two raises with Home, then exactly one bypass report for the episode`() {
        val policy = BlockRaisePolicy()
        val steps = (0 until 8).map { i -> policy.decide(youtube, WindowLayout.PICTURE_IN_PICTURE, false, 50_000L + i * 1_000L) }

        assertEquals(2, steps.count { it.raise })
        assertTrue(steps.filter { it.raise }.all { it.goHome })
        assertEquals("one alert per episode, not one per event", 1, steps.count { it.reportBypass })
        assertEquals(50_000L, steps.single { it.reportBypass }.episodeStartMs)
        assertTrue("nothing after the report", steps.drop(3).all { it == BlockRaise.NOTHING })
    }

    @Test
    fun `split screen - two raises, then one bypass report`() {
        val policy = BlockRaisePolicy()
        val steps = (0 until 5).map { i -> policy.decide(youtube, WindowLayout.SPLIT_SCREEN, false, i * 1_000L) }
        assertEquals(2, steps.count { it.raise })
        assertFalse("Home only for PiP or when the blocked app is active", steps.any { it.goHome })
        assertEquals(1, steps.count { it.reportBypass })
    }

    @Test
    fun `a debounced event does not use up one of the two raises`() {
        val policy = BlockRaisePolicy()
        assertTrue(policy.decide(youtube, WindowLayout.PICTURE_IN_PICTURE, false, 0L).raise)
        assertEquals(BlockRaise.NOTHING, policy.decide(youtube, WindowLayout.PICTURE_IN_PICTURE, false, 300L))
        assertTrue(policy.decide(youtube, WindowLayout.PICTURE_IN_PICTURE, false, 1_000L).raise)
        assertTrue(policy.decide(youtube, WindowLayout.PICTURE_IN_PICTURE, false, 2_000L).reportBypass)
    }

    @Test
    fun `the episode ends when no blocked window is seen, so the next PiP starts afresh`() {
        val policy = BlockRaisePolicy()
        repeat(4) { policy.decide(youtube, WindowLayout.PICTURE_IN_PICTURE, false, it * 1_000L) }
        policy.noBlockedWindow()
        val again = (0 until 3).map { policy.decide(youtube, WindowLayout.PICTURE_IN_PICTURE, false, 60_000L + it * 1_000L) }
        assertEquals(2, again.count { it.raise })
        assertEquals(60_000L, again.single { it.reportBypass }.episodeStartMs)
    }

    @Test
    fun `a PiP window that blinks out and back tells the parent once per ten minutes, not once per episode`() {
        val policy = BlockRaisePolicy()
        fun episode(start: Long) =
            (0 until 3).map { policy.decide(youtube, WindowLayout.PICTURE_IN_PICTURE, false, start + it * 1_000L) }
                .also { policy.noBlockedWindow() }
        assertEquals(1, episode(0L).count { it.reportBypass })
        assertEquals("the raises restart, the alert does not", 2, episode(30_000L).count { it.raise })
        assertEquals(0, episode(60_000L).count { it.reportBypass })
        assertEquals(1, episode(11 * 60_000L).count { it.reportBypass })
    }

    @Test
    fun `leaving PiP for the normal layout is a new episode with no budget`() {
        val policy = BlockRaisePolicy()
        repeat(4) { policy.decide(youtube, WindowLayout.PICTURE_IN_PICTURE, false, it * 1_000L) }
        val normal = policy.decide(youtube, WindowLayout.NORMAL, true, 10_000L)
        assertTrue(normal.raise && normal.goHome)
    }

    @Test
    fun `the PiP cover is added, kept, moved and removed as the window comes and goes`() {
        val corner = WindowBounds(600, 1500, 1000, 1800)
        val dragged = WindowBounds(40, 200, 440, 500)

        assertEquals(PipCoverAction.Keep, PipCoverDecision.decide(blockedPip = null, current = null))
        assertEquals(PipCoverAction.Add(corner), PipCoverDecision.decide(corner, null))
        assertEquals(PipCoverAction.Keep, PipCoverDecision.decide(corner, corner))
        assertEquals(PipCoverAction.Move(dragged), PipCoverDecision.decide(dragged, corner))
        assertEquals(PipCoverAction.Remove, PipCoverDecision.decide(null, dragged))
    }

    @Test
    fun `an empty rectangle is no PiP window to cover`() {
        val empty = WindowBounds(10, 10, 10, 300)
        assertEquals(PipCoverAction.Keep, PipCoverDecision.decide(empty, null))
        assertEquals(PipCoverAction.Remove, PipCoverDecision.decide(empty, WindowBounds(0, 0, 100, 100)))
    }

    @Test
    fun `the bypass alert names the app and layout, once per episode`() {
        val a = TamperAlertDedupe.blockBypassKey("dev-1", youtube, "picture_in_picture", 50_000L)
        assertEquals("dev-1|block_bypass|$youtube|picture_in_picture|50000", a)
        assertNotEquals(a, TamperAlertDedupe.blockBypassKey("dev-1", youtube, "picture_in_picture", 90_000L))
        assertEquals(
            mapOf("type" to "block_bypass", "app" to youtube, "layout" to "split_screen"),
            TamperAlertWorker.metadataFor(TamperAlertWorker.TYPE_BLOCK_BYPASS, youtube, "split_screen"),
        )
        assertEquals(
            mapOf("type" to TamperAlertWorker.TYPE_VPN_REVOKED),
            TamperAlertWorker.metadataFor(TamperAlertWorker.TYPE_VPN_REVOKED, youtube, "split_screen"),
        )
    }

    @Test
    fun `a second app's bypass does not replace the first one's pending work`() {
        val first = TamperAlertWorker.uniqueWorkName(TamperAlertWorker.TYPE_BLOCK_BYPASS, 50_000L, youtube)
        val second = TamperAlertWorker.uniqueWorkName(TamperAlertWorker.TYPE_BLOCK_BYPASS, 50_000L, meet)
        assertNotEquals(first, second)
    }
}
