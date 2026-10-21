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

    /**
     * Issue #267 review (D1, D2): what to add for one package, given which bucket the totals belong to.
     *
     * Android rolls its `INTERVAL_DAILY` bucket at a time the device picks — measured at 20:07 on the
     * Flip4, not at local midnight — so a snapshot keyed by the calendar date re-sent up to four hours
     * every morning. The bucket's own begin time is the key.
     *
     * And with **no snapshot at all** (a fresh pairing, or the first upload after install) the right
     * answer is zero plus a baseline: that total reaches back before OSRA was paired, and #229's rule is
     * that collection starts at the grant and never copies history. The event stream still covers the
     * window between the grant and this upload.
     *
     * @param sameBucket true when the snapshot was taken in the bucket these totals belong to
     * @param hasSnapshot false when there is no snapshot for this device yet
     */
    fun deltaForUpload(totalMinutes: Int, lastSeenMinutes: Int?, sameBucket: Boolean, hasSnapshot: Boolean): Int {
        if (totalMinutes <= 0) return 0
        if (!hasSnapshot) return 0
        // A new bucket is all usage since the rollover, so the whole total is new. The cost is that the
        // last upload before a rollover loses the tail of the previous bucket for apps the event stream
        // missed — one window a day, on the under-counting side, which is the side to be wrong on.
        if (!sameBucket) return totalMinutes
        return deltaMinutes(totalMinutes, lastSeenMinutes)
    }
}
