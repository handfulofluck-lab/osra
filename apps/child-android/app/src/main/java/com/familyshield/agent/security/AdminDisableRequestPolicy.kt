package com.familyshield.agent.security

/**
 * Pure policy for [GuardianAdminReceiver.onDisableRequested] (ADR-0010 §3, osra-security#78).
 *
 * Decides whether a system device-admin deactivation request should open [TamperGuardTaskActivity]
 * and record a remove-protection attempt, stand down inside an active parent-PIN grace or
 * sanctioned-removal window, or skip duplicate launches when the PIN gate is already covering the
 * screen.
 */
object AdminDisableRequestPolicy {

    enum class Action {
        /** Unpaired, setup not yet complete, no PIN configured, consent paused, or inside grace/sanctioned window. */
        ALLOW_WITHOUT_GATE,

        /** [TamperGuardTaskActivity] is already showing or mid-launch for the current attempt. */
        ALREADY_COVERED,

        /** Open [TamperGuardTaskActivity] over the system sheet and record the attempt. */
        LAUNCH_PIN_GATE,

        /**
         * Neither overlay permission nor a bound accessibility service is reported, so record the
         * attempt first and still attempt a best-effort activity start from the admin receiver callback.
         */
        RECORD_ATTEMPT_AND_BEST_EFFORT_GATE,
    }

    fun decide(
        paired: Boolean,
        setupCompletedOnce: Boolean,
        pinConfigured: Boolean,
        consentPaused: Boolean,
        nowMs: Long,
        graceUntilMs: Long,
        sanctionedUntilMs: Long,
        gateSuppressed: Boolean,
        canLaunchFromBackground: Boolean,
    ): Action {
        if (!paired || !setupCompletedOnce || !pinConfigured || consentPaused) {
            return Action.ALLOW_WITHOUT_GATE
        }
        if (nowMs < graceUntilMs || nowMs < sanctionedUntilMs) {
            return Action.ALLOW_WITHOUT_GATE
        }
        if (gateSuppressed) {
            return Action.ALREADY_COVERED
        }
        return if (canLaunchFromBackground) {
            Action.LAUNCH_PIN_GATE
        } else {
            Action.RECORD_ATTEMPT_AND_BEST_EFFORT_GATE
        }
    }
}
