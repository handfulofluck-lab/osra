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
        val until = IncomingRingWindow.next(isCall = true, hasDecline = true, hasHangUp = false, mode = CallAudioMode.NORMAL, nowMs = 10_000, fromDefaultDialer = true)
        assertEquals(10_000 + IncomingRingWindow.WINDOW_MS, until)
        assertTrue(IncomingRingWindow.isRinging(CallAudioMode.NORMAL, 11_000, until!!))
        // Bounded: after the window the phone is not exempt any more.
        assertFalse(IncomingRingWindow.isRinging(CallAudioMode.NORMAL, 10_000 + IncomingRingWindow.WINDOW_MS + 1, until))
    }

    /**
     * Antigravity's #851 finding on the Flip4: One UI posts the incoming-call notification from
     * `com.samsung.android.incallui`, not from `TelecomManager.defaultDialerPackage`. With the default-dialer
     * test alone, a silent ring on that handset set no window and the shade collapse hid the call's Answer.
     *
     * Mutant: make [IncomingRingWindow.fromTrustedSource] `pkg == defaultDialer` again and this row goes red
     * while every other row stays green — which is exactly how it shipped.
     */
    @Test
    fun `a platform in-call UI package may set the window, One UI's included`() {
        val samsung = IncomingRingWindow.fromTrustedSource(
            pkg = "com.samsung.android.incallui",
            defaultDialer = "com.samsung.android.dialer",
            platformInCallUi = EssentialPackages.inCallUi,
        )
        assertTrue(samsung)
        assertEquals(
            20_000 + IncomingRingWindow.WINDOW_MS,
            IncomingRingWindow.next(
                isCall = true,
                hasDecline = true,
                hasHangUp = false,
                mode = CallAudioMode.NORMAL,
                nowMs = 20_000,
                fromDefaultDialer = samsung,
            ),
        )
        // AOSP and Google shapes are trusted too, and the default dialer keeps working.
        assertTrue(IncomingRingWindow.fromTrustedSource("com.android.incallui", "com.android.dialer", EssentialPackages.inCallUi))
        assertTrue(IncomingRingWindow.fromTrustedSource("com.google.android.dialer", "com.google.android.dialer", EssentialPackages.inCallUi))
    }

    /**
     * Fable's rule survives the widening: an ordinary app that posts a call-style notification, with a
     * decline action and no hang-up, still cannot open the exemption.
     */
    @Test
    fun `an ordinary app posting a call notification cannot set the window`() {
        val trusted = IncomingRingWindow.fromTrustedSource(
            pkg = "com.example.chat",
            defaultDialer = "com.samsung.android.dialer",
            platformInCallUi = EssentialPackages.inCallUi,
        )
        assertFalse(trusted)
        assertNull(
            IncomingRingWindow.next(
                isCall = true,
                hasDecline = true,
                hasHangUp = false,
                mode = CallAudioMode.NORMAL,
                nowMs = 30_000,
                fromDefaultDialer = trusted,
            ),
        )
    }

    @Test
    fun `an audible ring needs no window, the audio mode already says so`() {
        assertNull(IncomingRingWindow.next(isCall = true, hasDecline = true, hasHangUp = false, mode = CallAudioMode.RINGTONE, nowMs = 1_000, fromDefaultDialer = true))
        assertTrue(IncomingRingWindow.isRinging(CallAudioMode.RINGTONE, 1_000, 0L))
    }

    @Test
    fun `answering clears the window, so the shade locks again during the call`() {
        assertEquals(0L, IncomingRingWindow.next(isCall = true, hasDecline = false, hasHangUp = true, mode = CallAudioMode.IN_CALL, nowMs = 20_000, fromDefaultDialer = true))
        assertFalse(IncomingRingWindow.isRinging(CallAudioMode.IN_CALL, 20_001, 0L))
    }

    @Test
    fun `a placed call is never exempt, even with a stale window`() {
        val until = 60_000L
        assertFalse(IncomingRingWindow.isRinging(CallAudioMode.IN_CALL, 30_000, until))
        assertFalse(IncomingRingWindow.isRinging(CallAudioMode.IN_COMMUNICATION, 30_000, until))
    }

    @Test
    fun `a call-style notification from another package cannot open the window`() {
        assertNull(IncomingRingWindow.next(isCall = true, hasDecline = true, hasHangUp = false, mode = CallAudioMode.NORMAL, nowMs = 1_000, fromDefaultDialer = false))
    }

    @Test
    fun `an ongoing notice from another app cannot close or open the window`() {
        // Fable: the default-dialer check runs before the ongoing-form clear, so another package cannot
        // move the window in either direction.
        assertNull(IncomingRingWindow.next(isCall = true, hasDecline = false, hasHangUp = true, mode = CallAudioMode.IN_CALL, nowMs = 2_000, fromDefaultDialer = false))
    }

    @Test
    fun `a notification that is not a call changes nothing`() {
        assertNull(IncomingRingWindow.next(isCall = false, hasDecline = true, hasHangUp = false, mode = CallAudioMode.NORMAL, nowMs = 1_000, fromDefaultDialer = true))
    }
}
