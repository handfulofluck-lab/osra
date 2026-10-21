package com.familyshield.agent.telemetry

import com.familyshield.agent.data.db.UsageEventEntity

/** Cap applied to a single inter-event gap (screen-off gaps are not usage). */
internal const val MAX_GAP_MS: Long = 5L * 60L * 1000L

/**
 * One aggregated window: whole minutes per app, the sub-minute ms left over for the next window, and
 * the packages this window's own events credited time to.
 */
internal data class PerAppUsage(
    val minutes: Map<String, Int>,
    val remainderMs: Map<String, Long>,
    /**
     * Packages the window's **events** mentioned, taken before [carriedMs] is merged in. The UsageStats
     * backfill must skip these even when they produced no whole minute: their time is already counted
     * here (as a minute now or as a carry later), and adding Android's increase on top double-counts
     * (review R1 on #281). A package that has only a carried remainder is deliberately absent — the
     * previous upload's snapshot already covered it, so Android's increase since then is real time.
     */
    val eventPackages: Set<String>,
)

/**
 * Pure aggregation (no Android classes — runs on the JVM): converts the ordered foreground-event
 * stream into per-app whole minutes. Each event earns the gap to the next event (capped at
 * [MAX_GAP_MS]); the last event earns the gap to [windowEnd]. Events must be sorted by timestamp
 * ascending (the DAO guarantees this).
 *
 * Gaps are summed in milliseconds and converted once, not floored gap by gap (#276): the phone's
 * status bar sends an event every ~60 s, so flooring each ~59.9 s gap credited zero all day. The
 * leftover ms of every package is returned so the caller can carry it into the next window —
 * without it, 15 windows of 59 s each still lose a minute apiece.
 */
internal fun computePerAppMinutes(
    events: List<UsageEventEntity>,
    windowEnd: Long,
    carriedMs: Map<String, Long> = emptyMap(),
): PerAppUsage {
    val perAppMs = HashMap<String, Long>()
    for (i in events.indices) {
        val next = if (i + 1 < events.size) events[i + 1].timestamp else windowEnd
        val gapMs = (next - events[i].timestamp).coerceIn(0L, MAX_GAP_MS)
        if (gapMs > 0) perAppMs.merge(events[i].packageId, gapMs) { a, b -> a + b }
    }
    // Taken before the carry is merged: the backfill's rule is "add only what this window's events did
    // not mention", and a carry is the previous window's time, already snapshotted once.
    val eventPackages = perAppMs.keys.toSet()
    for ((pkg, carried) in carriedMs) {
        if (carried > 0) perAppMs.merge(pkg, carried) { a, b -> a + b }
    }
    val minutes = HashMap<String, Int>()
    val remainderMs = HashMap<String, Long>()
    for ((pkg, totalMs) in perAppMs) {
        val wholeMinutes = (totalMs / 60_000L).toInt()
        if (wholeMinutes > 0) minutes[pkg] = wholeMinutes
        val rest = totalMs % 60_000L
        // Kept even with no minutes yet: that remainder is what makes the next window count.
        if (rest > 0) remainderMs[pkg] = rest
    }
    return PerAppUsage(minutes, remainderMs, eventPackages)
}
