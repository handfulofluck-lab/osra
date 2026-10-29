package com.familyshield.agent

import com.familyshield.agent.enforcement.CallAction
import com.familyshield.agent.enforcement.CallAudioMode
import com.familyshield.agent.enforcement.CallBlockPolicy
import com.familyshield.agent.enforcement.CallNotice
import com.familyshield.agent.enforcement.CallParcel
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Issue #444, Karim's rule and Claude's mechanisms from the #446 Flip4 measurements (M1–M4).
 * Meet is blocked; the dialer is essential; a messaging app is allowed.
 */
class CallBlockPolicyTest {

    private val meet = "com.google.android.apps.tachyon"
    private val dialer = "com.samsung.android.dialer"
    private val chat = "com.whatsapp"
    private var blocked = setOf(meet)
    private val isBlocked: (String) -> Boolean = { it in blocked }
    private val isEssential: (String) -> Boolean = { it == dialer }

    private fun ring(postedAt: Long = 1L) =
        CallParcel(isCall = true, hasDecline = true, hasHangUp = false, ongoing = false, postedAt = postedAt)

    private val ongoing = CallParcel(isCall = true, hasDecline = false, hasHangUp = true, ongoing = true, postedAt = 2L)

    private fun CallBlockPolicy.post(pkg: String, parcel: CallParcel?, now: Long = 0L) =
        onNotification(CallNotice(pkg, parcel), isBlocked, isEssential, now)

    private fun CallBlockPolicy.mode(m: CallAudioMode, now: Long = 0L) = onAudioMode(m, isBlocked, now)

    @Test
    fun `C1 unlocked - the decline is sent once per ring and the cover stays only while it rings`() {
        val p = CallBlockPolicy()
        assertEquals(listOf(CallAction.Decline(meet), CallAction.ShowRingCover), p.post(meet, ring()))
        assertEquals("the same ring again: nothing", emptyList<CallAction>(), p.post(meet, ring()))
        assertEquals(emptyList<CallAction>(), p.mode(CallAudioMode.RINGTONE))
        assertTrue(p.coverShown)
        assertEquals(listOf(CallAction.RemoveRingCover), p.mode(CallAudioMode.NORMAL))
        assertFalse(p.coverShown)
        assertEquals("a new ring is declined again", CallAction.Decline(meet), p.post(meet, ring(postedAt = 99L)).first())
    }

    @Test
    fun `C1 - an allowed app's ring is never touched`() {
        val p = CallBlockPolicy()
        assertEquals(emptyList<CallAction>(), p.post(chat, ring()))
        assertEquals(emptyList<CallAction>(), p.mode(CallAudioMode.RINGTONE))
    }

    @Test
    fun `C1 locked - no parcel, the last poster before the ring is blocked, so the lock screen is covered`() {
        val p = CallBlockPolicy()
        assertEquals(emptyList<CallAction>(), p.post(meet, parcel = null))
        assertEquals(listOf(CallAction.ShowRingCover), p.mode(CallAudioMode.RINGTONE))
        assertEquals(listOf(CallAction.RemoveRingCover), p.mode(CallAudioMode.NORMAL))
    }

    @Test
    fun `C1 locked - the cover is dropped at once when the dialer posts during the ring`() {
        val p = CallBlockPolicy()
        p.post(meet, parcel = null)
        p.mode(CallAudioMode.RINGTONE)
        assertEquals(listOf(CallAction.RemoveRingCover), p.post(dialer, parcel = null))
        assertFalse(p.coverShown)
        assertEquals("a later blocked ring event does not bring it back", emptyList<CallAction>(), p.post(meet, null))
    }

    @Test
    fun `the dialer is never covered, declined or hung up`() {
        val p = CallBlockPolicy()
        assertEquals(emptyList<CallAction>(), p.post(dialer, ring()))
        assertEquals(emptyList<CallAction>(), p.mode(CallAudioMode.RINGTONE))
        assertEquals(emptyList<CallAction>(), p.post(dialer, ongoing))
        assertEquals(emptyList<CallAction>(), p.mode(CallAudioMode.IN_CALL))
        assertTrue(p.tick(60_000L).isEmpty())
    }

    @Test
    fun `C1 - a ring that never sets RINGTONE does not leave the cover up for good`() {
        val p = CallBlockPolicy(coverMaxMs = 60_000L)
        p.post(meet, ring(), now = 0L)
        assertEquals(emptyList<CallAction>(), p.tick(59_999L))
        assertEquals(listOf(CallAction.RemoveRingCover), p.tick(60_000L))
    }

    @Test
    fun `C2 - a blocked call that connects is hung up with the cached intent`() {
        val p = CallBlockPolicy()
        p.post(meet, ongoing)
        assertEquals(listOf(CallAction.HangUp(meet)), p.mode(CallAudioMode.IN_COMMUNICATION, now = 1_000L))
        assertEquals("once", emptyList<CallAction>(), p.post(meet, ongoing))
    }

    @Test
    fun `C2 locked - with nothing cached, the first parcel after unlock hangs up`() {
        val p = CallBlockPolicy()
        p.post(meet, parcel = null)
        assertEquals(emptyList<CallAction>(), p.mode(CallAudioMode.IN_COMMUNICATION))
        assertEquals(listOf(CallAction.HangUp(meet)), p.post(meet, ongoing))
    }

    @Test
    fun `C2 - a call still up after 15 s is reported once, behind the per-app floor`() {
        val p = CallBlockPolicy()
        p.post(meet, ongoing)
        p.mode(CallAudioMode.IN_COMMUNICATION, now = 0L)
        assertEquals(emptyList<CallAction>(), p.tick(14_999L))
        assertEquals(listOf(CallAction.ReportCall(meet, 0L)), p.tick(15_000L))
        assertEquals(emptyList<CallAction>(), p.tick(30_000L))
        p.mode(CallAudioMode.NORMAL, now = 40_000L)
        p.post(meet, ongoing)
        p.mode(CallAudioMode.IN_COMMUNICATION, now = 60_000L)
        assertEquals("inside ten minutes: no second alert", emptyList<CallAction>(), p.tick(80_000L))
    }

    @Test
    fun `C2 - the call is the last call poster's, not an unrelated message's`() {
        val p = CallBlockPolicy()
        p.post(meet, ongoing)
        p.post(chat, CallParcel(isCall = false, hasDecline = false, hasHangUp = false, ongoing = false, postedAt = 5L))
        assertEquals(listOf(CallAction.HangUp(meet)), p.mode(CallAudioMode.IN_COMMUNICATION))
    }

    @Test
    fun `C3 - a call that connected before the block is left alone until NORMAL, then blocked`() {
        blocked = emptySet()
        val p = CallBlockPolicy()
        p.post(meet, ongoing)
        assertEquals(emptyList<CallAction>(), p.mode(CallAudioMode.IN_COMMUNICATION, now = 0L))
        blocked = setOf(meet) // the parent's rule arrives mid-call
        assertEquals("no hang-up mid-call", emptyList<CallAction>(), p.post(meet, ongoing))
        assertEquals("no alert either", emptyList<CallAction>(), p.tick(60_000L))
        p.mode(CallAudioMode.NORMAL)
        assertEquals("the next ring is blocked", CallAction.Decline(meet), p.post(meet, ring(postedAt = 7L)).first())
    }
}
