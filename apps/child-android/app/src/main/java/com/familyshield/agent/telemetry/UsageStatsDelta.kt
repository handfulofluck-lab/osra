package com.familyshield.agent.telemetry

/**
 * Issue #267: the UsageStats backfill must be a **delta**, like the event stream it stands behind.
 *
 * `UsageReporter` posts a delta every 15 minutes and the server adds each upload to the day (issue #31).
 * The backfill used to add Android's whole-day total for every package that this window's events did not
 * mention, so an app used once in the morning was added again on every later upload — the parent's "today"
 * grew without bound. Moving the query's start does not help: `UsageStatsManager` returns whole buckets
 * for `INTERVAL_DAILY`.
 *
 * So the totals Android reports are treated as a running counter and the upload sends the increase since
 * the last one. Pure, so the three cases are a JVM test rather than an arithmetic claim in a comment.
 */
object UsageStatsDelta {

    /**
     * What to add for one package this window.
     *
     * @param totalMinutes Android's whole-day total for the package now
     * @param lastSeenMinutes the same total at the previous upload, or null when this is the first upload
     *   of the day (or the first after a re-grant, where the caller establishes a baseline instead of
     *   adding anything)
     *
     * A total **below** the last one means the day rolled over (or the package's stats were reset), so the
     * whole total is new: a negative delta would subtract from a parent's screen time.
     */
    fun deltaMinutes(totalMinutes: Int, lastSeenMinutes: Int?): Int {
        if (totalMinutes <= 0) return 0
        if (lastSeenMinutes == null) return totalMinutes
        if (totalMinutes < lastSeenMinutes) return totalMinutes
        return totalMinutes - lastSeenMinutes
    }

    /** The baseline for a re-grant: everything Android has counted so far is excluded, not uploaded. */
    fun baseline(totals: Map<String, Int>): Map<String, Int> = totals.filterValues { it >= 0 }
}
