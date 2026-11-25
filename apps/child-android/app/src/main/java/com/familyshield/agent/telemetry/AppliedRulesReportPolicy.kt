package com.familyshield.agent.telemetry

/**
 * Karim 23 Nov: when the agent reports its applied rules version straight away.
 *
 * Only a version the phone has actually applied is reported (null means none was ever applied, and the
 * server treats "never reported" as not-behind). A version the server already accepted is not re-sent.
 */
object AppliedRulesReportPolicy {
    fun shouldReport(applied: Int?, lastReported: Int?): Boolean = applied != null && applied != lastReported

    /**
     * Codex #1002 review: the marker after an upload covering [version] succeeds. Two uploads can complete out
     * of order (the periodic one carrying 3 finishing after the immediate one carrying 4), so an older
     * acknowledgement never moves the marker back. A re-pair clears the marker, so null starts fresh.
     */
    fun acknowledged(current: Int?, version: Int): Int = if (current == null || version > current) version else current
}
