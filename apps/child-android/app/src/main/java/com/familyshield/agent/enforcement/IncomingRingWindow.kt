package com.familyshield.agent.enforcement

/**
 * #828 / #851 / osra-security#33: incoming cellular call exemption for the lock shade guard.
 *
 * Under a silent ringer or DND, `AudioManager.mode` stays `MODE_NORMAL` for the whole ring, so a
 * bounded 45-second window from a trusted dialer / platform `incallui` `CATEGORY_CALL` notification
 * provides the second signal. Under `osra-security#33`, `blockedRingActive` overrides `MODE_RINGTONE`
 * whenever a blocked or locked non-essential app owns the ring, preventing non-essential VoIP rings
 * from propping the shade open during a lock or pause.
 */
object IncomingRingWindow {
    const val WINDOW_MS = 45_000L

    fun next(
        isCall: Boolean,
        hasDecline: Boolean,
        hasHangUp: Boolean,
        mode: CallAudioMode,
        nowMs: Long,
        fromDefaultDialer: Boolean,
    ): Long? {
        if (!isCall) return null
        if (!fromDefaultDialer) return null
        if (hasHangUp) return 0L
        if (hasDecline && mode == CallAudioMode.NORMAL) return nowMs + WINDOW_MS
        return null
    }

    fun fromTrustedSource(pkg: String, defaultDialer: String?, platformInCallUi: Set<String>): Boolean =
        pkg == defaultDialer || pkg in platformInCallUi

    fun isRinging(
        mode: CallAudioMode,
        nowMs: Long,
        ringUntilMs: Long,
        blockedRingActive: Boolean = false,
    ): Boolean {
        if (blockedRingActive) return false
        return when {
            mode == CallAudioMode.RINGTONE -> true
            mode == CallAudioMode.NORMAL -> nowMs < ringUntilMs
            else -> false
        }
    }
}
