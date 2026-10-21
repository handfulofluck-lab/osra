package com.familyshield.agent.data

import java.time.LocalDate

/**
 * Pure (no Android classes) daily per-app minute counters extracted from RuleRepository so the
 * logic runs on the JVM. Usage is accumulated in milliseconds from consecutive foreground-event
 * gaps, each capped at [MAX_GAP_MS] (large gaps mean the screen was off), and converted to whole
 * minutes only when read (#276): the phone's status bar sends an event every ~60 s, so flooring
 * each gap lost every second of the day. Counters are in-memory only and reset when the local
 * date changes (the midnight WorkManager worker calls [resetIfNewDay] and [snapshot]/
 * [onForegroundEvent] self-heal on date change). Thread-safe via a monitor lock.
 *
 * [onForegroundEnded] closes the open interval for a window this stream deliberately never records —
 * the agent's own block screen (#284); without it the blocked app kept earning the whole stay.
 */
class UsageCounters {

    private val lock = Any()
    private val storedMs = HashMap<String, Long>()
    private var currentPkg: String? = null
    private var currentSinceMs: Long = 0L
    private var counterDay: LocalDate? = null

    /** Records a foreground transition for [packageId] at [timestampMs] (epoch millis). */
    fun onForegroundEvent(packageId: String, timestampMs: Long, today: LocalDate = LocalDate.now()) {
        synchronized(lock) {
            resetIfNewDayLocked(today)
            val prev = currentPkg
            if (prev != null) {
                val add = gapMs(timestampMs - currentSinceMs)
                if (add > 0) storedMs.merge(prev, add) { a, b -> a + b }
            }
            currentPkg = packageId
            currentSinceMs = timestampMs
        }
    }

    /**
     * Ends the open foreground interval at [timestampMs]: credits its gap to the app that was in
     * front, capped like any other gap, and leaves nothing open so [snapshotMs] credits no
     * in-progress time.
     *
     * Issue #284: the accessibility stream drops the agent's own package on purpose, so our block
     * screen never produced an event and the blocked app's interval stayed open for the whole stay —
     * charged to that app by the next event (Home, another app), or capped at [MAX_GAP_MS] but
     * charged all the same. Waiting on "This app is blocked by your parent" is not use of the app
     * behind it: it spent the daily limit, and it spent a "Request access" bonus before the parent
     * had granted it.
     */
    fun onForegroundEnded(timestampMs: Long, today: LocalDate = LocalDate.now()) {
        synchronized(lock) {
            resetIfNewDayLocked(today)
            currentPkg?.let { prev ->
                val add = gapMs(timestampMs - currentSinceMs)
                if (add > 0) storedMs.merge(prev, add) { a, b -> a + b }
            }
            currentPkg = null
        }
    }

    /**
     * Returns today's minutes per package, crediting up to [MAX_GAP_MS] of in-progress foreground
     * time for the current app. Resets first when the date has rolled over.
     */
    fun snapshot(nowMs: Long, today: LocalDate = LocalDate.now()): Map<String, Int> =
        snapshotMs(nowMs, today)
            .mapNotNull { (pkg, ms) -> (ms / 60_000L).toInt().takeIf { it > 0 }?.let { pkg to it } }
            .toMap()

    /**
     * Today's per-package usage in milliseconds, including the in-progress credit. Persisted
     * instead of [snapshot] so a restart keeps the sub-minute remainder (#276).
     */
    fun snapshotMs(nowMs: Long, today: LocalDate = LocalDate.now()): Map<String, Long> =
        synchronized(lock) {
            resetIfNewDayLocked(today)
            val map = HashMap(storedMs)
            currentPkg?.let { cur ->
                val add = gapMs(nowMs - currentSinceMs)
                if (add > 0) map.merge(cur, add) { a, b -> a + b }
            }
            map
        }

    /** Clears the counters when [today] differs from the counter day (no-op otherwise). */
    fun resetIfNewDay(today: LocalDate = LocalDate.now()) = synchronized(lock) {
        resetIfNewDayLocked(today)
    }

    /**
     * Rebuilds the counter state from a chronological sequence of foreground transitions for [today].
     * Capped per-gap at [MAX_GAP_MS].
     *
     * [ownPackage] is replayed as an **interval end**, not as an app (#284): our own window never earns
     * time, but its event does close the app behind it. Dropping those events instead would hand the
     * overlay's whole stay to the blocked app — the bug this parameter exists to prevent, on the startup
     * path rather than the live one.
     */
    fun rebuildFromEvents(
        events: List<Pair<String, Long>>,
        today: LocalDate = LocalDate.now(),
        ownPackage: String? = null,
    ) {
        synchronized(lock) {
            resetIfNewDayLocked(today)
            storedMs.clear()
            currentPkg = null
            currentSinceMs = 0L
            for ((pkg, ts) in events) {
                if (pkg == ownPackage) onForegroundEnded(ts, today) else onForegroundEvent(pkg, ts, today)
            }
        }
    }

    /**
     * Restores counters from a previously saved snapshot of per-app milliseconds for [today].
     *
     * Merged rather than replacing: an accessibility event can arrive before the startup restore runs
     * (#286), and clearing here would throw away the seconds it had already counted. A fresh counter is
     * empty, so the merge is a plain copy on the normal path.
     */
    fun restore(
        persistedMs: Map<String, Long>,
        today: LocalDate = LocalDate.now(),
    ) {
        synchronized(lock) {
            resetIfNewDayLocked(today)
            for ((pkg, ms) in persistedMs) {
                if (ms > 0) storedMs.merge(pkg, ms) { a, b -> a + b }
            }
            currentPkg = null
            currentSinceMs = 0L
        }
    }

    private fun resetIfNewDayLocked(today: LocalDate) {
        if (counterDay != today) {
            storedMs.clear()
            currentPkg = null
            counterDay = today
        }
    }

    private fun gapMs(gapMs: Long): Long = gapMs.coerceIn(0L, MAX_GAP_MS)

    companion object {
        /** Cap applied to a single foreground gap (screen-off gaps are not usage). */
        const val MAX_GAP_MINUTES: Int = 5

        /** [MAX_GAP_MINUTES] in milliseconds, the unit the counters actually accumulate. */
        const val MAX_GAP_MS: Long = MAX_GAP_MINUTES * 60_000L
    }
}
