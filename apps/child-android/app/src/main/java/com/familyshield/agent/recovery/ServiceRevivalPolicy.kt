package com.familyshield.agent.recovery

/**
 * Pure policy for immediate post-removal / post-destroy service revival (osra-security#78).
 *
 * Schedules a short wakeup only when a paired, active (non-consent-paused, non-unlinking) agent
 * service is torn down without an explicit stop command.
 */
object ServiceRevivalPolicy {

    /** Delay before the `AlarmManager` revival broadcast fires after task removal / service teardown. */
    const val REVIVAL_DELAY_MS: Long = 1_500L

    const val ACTION_REVIVE_SERVICES: String = "com.familyshield.agent.action.REVIVE_SERVICES"

    fun shouldScheduleOnServiceExit(
        paired: Boolean,
        consentPaused: Boolean,
        unlinkPending: Boolean = false,
        explicitlyStopping: Boolean = false,
    ): Boolean = paired && !consentPaused && !unlinkPending && !explicitlyStopping

    fun shouldRunStartupRecovery(unlinkPending: Boolean): Boolean = !unlinkPending
}
