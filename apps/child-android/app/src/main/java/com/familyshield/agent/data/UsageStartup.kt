package com.familyshield.agent.data

import java.time.LocalDate

/** Where today's usage counters come from when the process starts (#286). */
internal enum class UsageStartupSource {
    /** The persisted snapshot for today: the whole day, minus at most the one gap the process died in. */
    SNAPSHOT,

    /** No snapshot for today — replay Room's events since midnight (AND-02's original fallback). */
    ROOM_EVENTS,

    /** Neither: a fresh day. */
    EMPTY,
}

internal data class UsageStartup(
    val source: UsageStartupSource,
    /** Restored counters in ms; empty unless [source] is [UsageStartupSource.SNAPSHOT]. */
    val countersMs: Map<String, Long>,
)

/**
 * The saved snapshot **wins**; Room is the fallback, not a second opinion (#286).
 *
 * This used to run both in sequence: restore the snapshot, then rebuild from Room's events whenever any
 * existed. Every upload deletes the events it sent, so after the first upload of the day Room only holds
 * the time since that upload — and the rebuild *cleared* the counters first. A restart, an app update or
 * a reboot therefore replaced the day's counters with the last ~15 minutes, which unlocked used-up
 * per-app and daily limits. That is a bypass a child can perform deliberately, so the precedence is a
 * one-line rule that has to be explicit rather than an accident of call order.
 */
internal fun planUsageStartup(
    savedMs: Map<String, Long>?,
    savedDate: String?,
    today: LocalDate,
    roomEventCount: Int,
): UsageStartup = when {
    savedMs != null && savedDate == today.toString() ->
        UsageStartup(UsageStartupSource.SNAPSHOT, savedMs)
    roomEventCount > 0 -> UsageStartup(UsageStartupSource.ROOM_EVENTS, emptyMap())
    else -> UsageStartup(UsageStartupSource.EMPTY, emptyMap())
}
