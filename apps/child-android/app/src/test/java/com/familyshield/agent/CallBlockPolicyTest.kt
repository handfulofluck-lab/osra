package com.familyshield.agent

import com.familyshield.agent.enforcement.BlockRaisePolicy
import com.familyshield.agent.enforcement.BypassAlertFloor
import com.familyshield.agent.enforcement.CallAction
import com.familyshield.agent.enforcement.CallAudioMode
import com.familyshield.agent.enforcement.CallBlockPolicy
import com.familyshield.agent.enforcement.CallNotice
import com.familyshield.agent.enforcement.CallParcel
import com.familyshield.agent.enforcement.WindowLayout
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Issue #444, Karim's rule and Claude's mechanisms from the #446 Flip4 measurements (M1–M4), with the #449
 * review's fixes. Meet and YouTube are blocked; the dialer is essential; a messaging app is allowed.
 */
class CallBlockPolicyTest {

    private val meet = "com.google.android.apps.tachyon"
    private val youtube = "com.google.android.youtube"
    private val dialer = "com.samsung.android.dialer"
    private val chat = "com.whatsapp"
    private var blocked = setOf(meet, youtube)
    private val isBlocked: (String) -> Boolean = { it in blocked }
    private val isEssential: (String) -> Boolean = { it == dialer }

    /** The Flip4's Meet ring, as M1 recorded it: CallStyle, ongoing, with decline, answer and hang-up. */
    private fun ring(postedAt: Long = 1L) =
        CallParcel(isCall = true, hasDecline = true, hasHangUp = true, ongoing = true, postedAt = postedAt)

    private val ongoing = CallParcel(isCall = true, hasDecline = false, hasHangUp = true, ongoing = true, postedAt = 2L)
    private val message = CallParcel(isCall = false, hasDecline = false, hasHangUp = false, ongoing = false, postedAt = 3L)

    private fun CallBlockPolicy.post(pkg: String, parcel: CallParcel?, now: Long = 0L) =
        onNotification(CallNotice(pkg, parcel), isBlocked, isEssential, now)

    private fun CallBlockPolicy.mode(m: CallAudioMode, now: Long = 0L) = onAudioMode(m, isBlocked, now)

    @Test
    fun `C1 unlocked - the M1 ring (ongoing=true) is declined once and covered while it rings`() {
        val p = CallBlockPolicy()
        assertEquals(listOf(CallAction.Decline(meet), CallAction.ShowRingCover), p.post(meet, ring(), now = 0L))
        assertEquals("the same ring again: nothing", emptyList<CallAction>(), p.post(meet, ring(), now = 100L))
        assertEquals(emptyList<CallAction>(), p.mode(CallAudioMode.RINGTONE, now = 200L))
        assertTrue(p.coverShown)
        assertEquals(listOf(CallAction.RemoveRingCover), p.mode(CallAudioMode.NORMAL, now = 3_000L))
        assertFalse(p.coverShown)
        assertEquals("a new ring is declined again", CallAction.Decline(meet), p.post(meet, ring(postedAt = 99L), now = 9_000L).first())
    }

    @Test
    fun `C1 unlocked - a ring whose decline ends it before RINGTONE leaves the cover up about five seconds`() {
        val p = CallBlockPolicy()
        p.post(meet, ring(), now = 0L)
        assertEquals(emptyList<CallAction>(), p.tick(4_999L))
        assertEquals(listOf(CallAction.RemoveRingCover), p.tick(5_000L))
    }

    @Test
    fun `C1 - once RINGTONE is seen the cover may stay up to a minute, never longer`() {
        val p = CallBlockPolicy()
        p.post(meet, ring(), now = 0L)
        p.mode(CallAudioMode.RINGTONE, now = 1_000L)
        assertEquals(emptyList<CallAction>(), p.tick(60_999L))
        assertEquals(listOf(CallAction.RemoveRingCover), p.tick(61_000L))
    }

    @Test
    fun `C1 - an allowed app's ring is never touched`() {
        val p = CallBlockPolicy()
        assertEquals(emptyList<CallAction>(), p.post(chat, ring()))
        assertEquals(emptyList<CallAction>(), p.mode(CallAudioMode.RINGTONE, now = 500L))
    }

    @Test
    fun `C1 locked - no parcel, a blocked app posted just before the ring, so the lock screen is covered`() {
        val p = CallBlockPolicy()
        assertEquals(emptyList<CallAction>(), p.post(meet, parcel = null, now = 0L))
        assertEquals(listOf(CallAction.ShowRingCover), p.mode(CallAudioMode.RINGTONE, now = 800L))
        assertEquals(listOf(CallAction.RemoveRingCover), p.mode(CallAudioMode.NORMAL, now = 20_000L))
    }

    @Test
    fun `C1 locked - the cover is dropped at once when the dialer posts during the ring`() {
        val p = CallBlockPolicy()
        p.post(meet, parcel = null, now = 0L)
        p.mode(CallAudioMode.RINGTONE, now = 500L)
        assertEquals(listOf(CallAction.RemoveRingCover), p.post(dialer, parcel = null, now = 900L))
        assertFalse(p.coverShown)
        assertEquals("a later blocked ring event does not bring it back", emptyList<CallAction>(), p.post(meet, null, now = 1_000L))
    }

    @Test
    fun `B5 - RINGTONE before the ring's own event - the blocked post takes the ring, covers it, and its call is hung up`() {
        val p = CallBlockPolicy()
        assertEquals("nobody fresh yet", emptyList<CallAction>(), p.mode(CallAudioMode.RINGTONE, now = 0L))
        assertEquals(listOf(CallAction.ShowRingCover), p.post(meet, parcel = null, now = 300L))
        assertEquals("ringing: the long limit, not five seconds", emptyList<CallAction>(), p.tick(10_000L))
        assertEquals(listOf(CallAction.RemoveRingCover), p.mode(CallAudioMode.IN_COMMUNICATION, now = 12_000L))
        assertEquals(listOf(CallAction.HangUp(meet)), p.post(meet, ongoing, now = 13_000L))
    }

    @Test
    fun `M5 - a stale blocked poster never covers, hangs up or reports a later allowed call`() {
        val p = CallBlockPolicy()
        p.post(youtube, parcel = null, now = 0L)
        assertEquals("30 s later: nothing fresh, no cover", emptyList<CallAction>(), p.mode(CallAudioMode.RINGTONE, now = 30_000L))
        assertEquals(emptyList<CallAction>(), p.mode(CallAudioMode.IN_COMMUNICATION, now = 32_000L))
        assertEquals("no alert either", emptyList<CallAction>(), p.tick(120_000L))
    }

    @Test
    fun `the dialer is never covered, declined, hung up or reported`() {
        val p = CallBlockPolicy()
        assertEquals(emptyList<CallAction>(), p.post(dialer, ring(), now = 0L))
        assertEquals(emptyList<CallAction>(), p.mode(CallAudioMode.RINGTONE, now = 100L))
        assertEquals(emptyList<CallAction>(), p.post(dialer, ongoing, now = 200L))
        assertEquals(emptyList<CallAction>(), p.mode(CallAudioMode.IN_CALL, now = 300L))
        assertTrue(p.tick(60_000L).isEmpty())
    }

    @Test
    fun `C2 - an outgoing blocked call that connects is hung up with the cached intent`() {
        val p = CallBlockPolicy()
        p.post(meet, ongoing, now = 0L)
        assertEquals(listOf(CallAction.HangUp(meet)), p.mode(CallAudioMode.IN_COMMUNICATION, now = 1_000L))
        assertEquals("once", emptyList<CallAction>(), p.post(meet, ongoing, now = 2_000L))
    }

    @Test
    fun `C2 - an outgoing call whose notification follows the mode change is still hung up`() {
        val p = CallBlockPolicy()
        assertEquals(emptyList<CallAction>(), p.mode(CallAudioMode.IN_COMMUNICATION, now = 0L))
        assertEquals(listOf(CallAction.HangUp(meet)), p.post(meet, ongoing, now = 1_500L))
    }

    @Test
    fun `C2 locked - the ringing app owns the call, and the first parcel after unlock hangs up`() {
        val p = CallBlockPolicy()
        p.post(meet, parcel = null, now = 0L)
        p.mode(CallAudioMode.RINGTONE, now = 500L)
        assertEquals(listOf(CallAction.RemoveRingCover), p.mode(CallAudioMode.IN_COMMUNICATION, now = 9_000L))
        assertEquals(listOf(CallAction.HangUp(meet)), p.post(meet, ongoing, now = 30_000L))
    }

    @Test
    fun `C2 - a call still up after 10 s is reported once`() {
        val p = CallBlockPolicy()
        p.post(meet, ongoing, now = 0L)
        p.mode(CallAudioMode.IN_COMMUNICATION, now = 0L)
        // One millisecond short: a call that ends as the block screen rises must not page the parent.
        assertEquals(emptyList<CallAction>(), p.tick(9_999L))
        assertEquals(listOf(CallAction.ReportCall(meet, 0L)), p.tick(10_000L))
        assertEquals(emptyList<CallAction>(), p.tick(30_000L))
    }

    @Test
    fun `a split-screen alert followed by a call inside the floor sends once (#444 review)`() {
        // Claude's row: the floor is per app, so the second path must not page the parent again.
        val floor = BypassAlertFloor()
        val windows = BlockRaisePolicy(floor = floor)
        repeat(3) { windows.decide(meet, WindowLayout.SPLIT_SCREEN, false, it * 1_000L) }
        val calls = CallBlockPolicy(floor = floor)
        calls.post(meet, ongoing, now = 20_000L)
        calls.mode(CallAudioMode.IN_COMMUNICATION, now = 20_000L)
        assertEquals(
            "the split-screen alert already paged the parent",
            emptyList<CallAction>(),
            calls.tick(40_000L),
        )
    }

    @Test
    fun `the call alert and the PiP alert share one per-app floor`() {
        val floor = BypassAlertFloor()
        val windows = BlockRaisePolicy(floor = floor)
        repeat(3) { windows.decide(meet, WindowLayout.PICTURE_IN_PICTURE, false, it * 1_000L) }
        val calls = CallBlockPolicy(floor = floor)
        calls.post(meet, ongoing, now = 10_000L)
        calls.mode(CallAudioMode.IN_COMMUNICATION, now = 10_000L)
        assertEquals("the PiP alert at 2 s already paged the parent", emptyList<CallAction>(), calls.tick(30_000L))
    }

    @Test
    fun `C2 - the call is the last call poster's, not an unrelated message's`() {
        val p = CallBlockPolicy()
        p.post(meet, ongoing, now = 0L)
        p.post(chat, message, now = 100L)
        assertEquals(listOf(CallAction.HangUp(meet)), p.mode(CallAudioMode.IN_COMMUNICATION, now = 200L))
    }

    @Test
    fun `C3 - a call that connected before the block is left alone until NORMAL, then blocked`() {
        blocked = emptySet()
        val p = CallBlockPolicy()
        p.post(meet, ongoing, now = 0L)
        assertEquals(emptyList<CallAction>(), p.mode(CallAudioMode.IN_COMMUNICATION, now = 100L))
        blocked = setOf(meet) // the parent's rule arrives mid-call
        assertEquals("no hang-up mid-call", emptyList<CallAction>(), p.post(meet, ongoing, now = 1_000L))
        assertEquals("no alert either", emptyList<CallAction>(), p.tick(60_000L))
        p.mode(CallAudioMode.NORMAL, now = 70_000L)
        assertEquals("the next ring is blocked", CallAction.Decline(meet), p.post(meet, ring(postedAt = 7L), now = 80_000L).first())
    }
}
