package com.familyshield.agent.telemetry

/**
 * Karim 23 Nov: when the agent reports its applied rules version straight away.
 *
 * Only a version the phone has actually applied is reported (null means none was ever applied, and the
 * server treats "never reported" as not-behind). A version the server already accepted is not re-sent.
 */
object AppliedRulesReportPolicy {
    fun shouldReport(applied: Int?, lastReported: Int?): Boolean = applied != null && applied != lastReported
}
