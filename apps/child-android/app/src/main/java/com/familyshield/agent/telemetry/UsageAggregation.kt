package com.familyshield.agent.telemetry

import com.familyshield.agent.data.db.UsageEventEntity

/** Cap applied to a single inter-event gap (screen-off gaps are not usage). */
internal const val MAX_GAP_MS: Long = 5L * 60L * 1000L

/**
 * Pure aggregation (no Android classes — runs on the JVM): converts the ordered foreground-event
 * stream into per-app whole minutes. Each event earns the gap to the next event (capped at
 * [MAX_GAP_MS]); the last event earns the gap to [windowEnd]. Events must be sorted by timestamp
 * ascending (the DAO guarantees this).
 */
internal fun computePerAppMinutes(
    events: List<UsageEventEntity>,
    windowEnd: Long,
): Map<String, Int> {
    val perApp = HashMap<String, Int>()
    for (i in events.indices) {
        val next = if (i + 1 < events.size) events[i + 1].timestamp else windowEnd
        val minutes = ((next - events[i].timestamp).coerceIn(0L, MAX_GAP_MS) / 60_000L).toInt()
        if (minutes > 0) perApp.merge(events[i].packageId, minutes) { a, b -> a + b }
    }
    return perApp
}
