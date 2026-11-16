package com.familyshield.agent.enforcement

/**
 * #828 (Antigravity's blocker 2 on the Android 14 device run): under a silent ringer or DND, Telecom
 * suppresses the ringtone's audio focus for the whole ring, so `AudioManager.mode` stays `MODE_NORMAL`
 * while the phone is actively ringing. The audio-mode check alone therefore answered "not ringing" and
 * the shade collapse hid the incoming-call heads-up — including its Answer.
 *
 * The call notification is the second signal, and it needs no permission the Play flavour lacks:
 * an incoming call posts `CATEGORY_CALL` with `EXTRA_DECLINE` and no `EXTRA_HANG_UP`; once the call is
 * answered or another call is placed, the notification becomes the ongoing form (`EXTRA_HANG_UP`). A
 * bounded window from that notification covers every ringer state — audible, silent, DND — while an
 * answered or placed call is never exempt for longer than the window could hide a ring.
 */
object IncomingRingWindow {
    /** A cellular ring is at most ~45 s before voicemail; a longer window would only hide real use. */
    const val WINDOW_MS = 45_000L

    /**
     * The new deadline from one call notification, or null when the notice does not change it.
     * [mode] is the audio mode: with a real ringtone the mode already covers the ring, and the window is
     * only needed for the silent/DND case.
     */
    fun next(
        isCall: Boolean,
        hasDecline: Boolean,
        hasHangUp: Boolean,
        mode: CallAudioMode,
        nowMs: Long,
        fromDefaultDialer: Boolean,
    ): Long? {
        if (!isCall) return null
        // Fable: only the system default dialer may move the window, in either direction. Any app that can
        // post a call-style notification could otherwise hold the exemption open (or close it) at will,
        // which is osra-security#33 again. The dialer check therefore precedes the ongoing-form clear.
        if (!fromDefaultDialer) return null
        if (hasHangUp) return 0L
        if (hasDecline && mode == CallAudioMode.NORMAL) return nowMs + WINDOW_MS
        return null
    }

    /** Whether an incoming call is ringing now, from the two signals together. */
    fun isRinging(mode: CallAudioMode, nowMs: Long, ringUntilMs: Long): Boolean = when {
        mode == CallAudioMode.RINGTONE -> true
        mode == CallAudioMode.NORMAL -> nowMs < ringUntilMs
        // Placed, answered (cellular or VoIP): never exempt, so the shade locks again.
        else -> false
    }
}
