package com.familyshield.agent.comms

/**
 * Issue #91: whether a call/SMS harvest may run, and whether the reason is worth saying once.
 *
 * The previous code queried first and caught `SecurityException`, logging a full stack at W on every
 * session of every device without `READ_CALL_LOG`/`READ_SMS`. That is how a log tag becomes noise nobody
 * reads. The decision is three-state and pure so the "say it once, not per event" part is testable
 * without Android.
 */
object CommsAccessPolicy {

    enum class Decision {
        /** Permission present: run the harvest. */
        HARVEST,

        /** Permission absent and already reported in this process: return silently. */
        SKIP_QUIETLY,

        /** Permission absent and not yet reported: log once at INFO, then set the flag. */
        SKIP_AND_REPORT,
    }

    fun decide(hasPermission: Boolean, alreadyReported: Boolean): Decision = when {
        hasPermission -> Decision.HARVEST
        alreadyReported -> Decision.SKIP_QUIETLY
        else -> Decision.SKIP_AND_REPORT
    }
}
