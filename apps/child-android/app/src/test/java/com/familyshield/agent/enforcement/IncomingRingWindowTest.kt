package com.familyshield.agent.enforcement

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * #828 (Antigravity, Android 14 device run): under a silent ringer or DND, Telecom suppresses the
 * ringtone's audio focus for the whole ring, so `AudioManager.mode` stays `MODE_NORMAL` while the phone
 * rings. The old check (`mode == RINGTONE`) answered "not ringing" and the shade collapse hid Answer.
 *
 * Mutant to try: return `mode == RINGTONE` from [IncomingRingWindow.isRinging]; the silent-ring rows go
 * red. Or make [IncomingRingWindow.next] ignore `hasHangUp`; the answered-call row goes red.
 */
class IncomingRingWindowTest {

    @Test
    fun `a silent or DND ring sets a bounded window from the call notification`() {
        val until = IncomingRingWindow.next(isCall = true, hasDecline = true, hasHangUp = false, mode = CallAudioMode.NORMAL, nowMs = 10_000)
        assertEquals(10_000 + IncomingRingWindow.WINDOW_MS, until)
        assertTrue(IncomingRingWindow.isRinging(CallAudioMode.NORMAL, 11_000, until!!))
        // Bounded: after the window the phone is not exempt any more.
        assertFalse(IncomingRingWindow.isRinging(CallAudioMode.NORMAL, 10_000 + IncomingRingWindow.WINDOW_MS + 1, until))
    }

    @Test
    fun `an audible ring needs no window, the audio mode already says so`() {
        assertNull(IncomingRingWindow.next(isCall = true, hasDecline = true, hasHangUp = false, mode = CallAudioMode.RINGTONE, nowMs = 1_000))
        assertTrue(IncomingRingWindow.isRinging(CallAudioMode.RINGTONE, 1_000, 0L))
    }

    @Test
    fun `answering clears the window, so the shade locks again during the call`() {
        assertEquals(0L, IncomingRingWindow.next(isCall = true, hasDecline = false, hasHangUp = true, mode = CallAudioMode.IN_CALL, nowMs = 20_000))
        assertFalse(IncomingRingWindow.isRinging(CallAudioMode.IN_CALL, 20_001, 0L))
    }

    @Test
    fun `a placed call is never exempt, even with a stale window`() {
        val until = 60_000L
        assertFalse(IncomingRingWindow.isRinging(CallAudioMode.IN_CALL, 30_000, until))
        assertFalse(IncomingRingWindow.isRinging(CallAudioMode.IN_COMMUNICATION, 30_000, until))
    }

    @Test
    fun `a notification that is not a call changes nothing`() {
        assertNull(IncomingRingWindow.next(isCall = false, hasDecline = true, hasHangUp = false, mode = CallAudioMode.NORMAL, nowMs = 1_000))
    }
}
