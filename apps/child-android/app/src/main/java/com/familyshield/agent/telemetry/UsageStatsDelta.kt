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
     * Issue #267 review (D3): is this a real rollover, or a clock change that moved the bucket's key?
     *
     * Android shifts every interval when the wall clock moves — `firstTimeStamp` changes while the
     * counters stay put, and the change is not confined to a child: a network time correction above a
     * couple of seconds does it too. Treating a moved key as a rollover re-sent every package's whole
     * total, which is #267 again triggered by one clock change.
     *
     * The counters are the evidence: inside one bucket they never go down, and a rollover restarts them.
     * So a new key is a rollover only if some package's total dropped below its snapshot, or a package
     * that had minutes in the snapshot is gone from the newest bucket. Otherwise the same bucket has
     * moved and the increases are what is new.
     *
     * The one case this cannot tell apart — a real rollover where every app is already above yesterday's
     * count before the first upload — falls back to increments. That under-counts by at most one upload
     * window, which is the side to be wrong on.
     */
    fun isRollover(
        storedBucket: Long?,
        bucketBegin: Long,
        lastSeen: Map<String, Int>,
        totals: Map<String, Int>,
    ): Boolean {
        if (storedBucket == null) return false // no snapshot: the caller records a baseline and adds nothing
        if (storedBucket == bucketBegin) return false
        val counterRestarted = totals.any { (pkg, total) ->
            lastSeen[pkg]?.let { total < it } == true
        }
        val vanished = lastSeen.any { (pkg, seen) -> seen > 0 && !totals.containsKey(pkg) }
        return counterRestarted || vanished
    }

    /**
     * Issue #267 review (D1, D2): what to add for one package, given the bucket decision.
     *
     * With **no snapshot at all** (a fresh pairing, or the first upload after install) the right answer is
     * zero plus a baseline: that total reaches back before OSRA was paired, and #229's rule is that
     * collection starts at the grant and never copies history. The event stream still covers the window
     * between the grant and this upload.
     *
     * @param rollover true when [isRollover] decided the counters restarted — a new bucket's totals are
     *   all new, and the cost is the tail of the last bucket before the rollover for apps the event stream
     *   missed: one window a day, on the under-counting side.
     */
    fun deltaForUpload(totalMinutes: Int, lastSeenMinutes: Int?, rollover: Boolean, hasSnapshot: Boolean): Int {
        if (totalMinutes <= 0) return 0
        if (!hasSnapshot) return 0
        if (rollover) return totalMinutes
        return deltaMinutes(totalMinutes, lastSeenMinutes)
    }
}
