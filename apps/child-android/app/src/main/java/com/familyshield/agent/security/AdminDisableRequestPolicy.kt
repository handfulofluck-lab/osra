package com.familyshield.agent.security

/**
 * Pure policy for [GuardianAdminReceiver.onDisableRequested] (ADR-0010 §3, osra-security#78).
 *
 * Decides whether a system device-admin deactivation request should revive stopped services, open
 * [TamperGuardTaskActivity], and record a remove-protection attempt, or stand down during an
 * approved unlink, consent pause, parent-PIN grace window, or sanctioned removal.
 */
object AdminDisableRequestPolicy {

    enum class Action {
        /** Unpaired, unlink pending, setup incomplete, no PIN, consent paused, or inside grace/sanctioned window. */
        ALLOW_WITHOUT_GATE,

        /** [TamperGuardTaskActivity] is already showing or mid-launch for the current attempt. */
        ALREADY_COVERED,

        /** Revive services, open [TamperGuardTaskActivity] over the system sheet, and record the attempt. */
        LAUNCH_PIN_GATE,

        /**
         * Neither overlay permission nor a bound accessibility service is reported, so revive
         * services, record the attempt, and attempt a best-effort activity start from the admin callback.
         */
        RECORD_ATTEMPT_AND_BEST_EFFORT_GATE,
    }

    fun decide(
        paired: Boolean,
        unlinkPending: Boolean = false,
        setupCompletedOnce: Boolean,
        pinConfigured: Boolean,
        consentPaused: Boolean,
        nowMs: Long,
        graceUntilMs: Long,
        sanctionedUntilMs: Long,
        gateSuppressed: Boolean,
        canLaunchFromBackground: Boolean,
    ): Action {
        if (!paired || unlinkPending || !setupCompletedOnce || !pinConfigured || consentPaused) {
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
