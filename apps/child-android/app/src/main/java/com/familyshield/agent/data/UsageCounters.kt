package com.familyshield.agent.data

import java.time.LocalDate

/**
 * Pure (no Android classes) daily per-app minute counters extracted from RuleRepository so the
 * logic runs on the JVM. Minutes are computed from consecutive foreground-event gaps, capped at
 * [MAX_GAP_MINUTES] per gap (large gaps mean the screen was off). Counters are in-memory only and
 * reset when the local date changes (the midnight WorkManager worker calls [resetIfNewDay] and
 * [snapshot]/[onForegroundEvent] self-heal on date change). Thread-safe via a monitor lock.
 */
class UsageCounters {

    private val lock = Any()
    private val storedMinutes = HashMap<String, Int>()
    private var currentPkg: String? = null
    private var currentSinceMs: Long = 0L
    private var counterDay: LocalDate? = null

    /** Records a foreground transition for [packageId] at [timestampMs] (epoch millis). */
    fun onForegroundEvent(packageId: String, timestampMs: Long, today: LocalDate = LocalDate.now()) {
        synchronized(lock) {
            resetIfNewDayLocked(today)
            val prev = currentPkg
            if (prev != null) {
                val add = gapMinutes(timestampMs - currentSinceMs)
                if (add > 0) storedMinutes.merge(prev, add) { a, b -> a + b }
            }
            currentPkg = packageId
            currentSinceMs = timestampMs
        }
    }

    /**
     * Returns today's minutes per package, crediting up to [MAX_GAP_MINUTES] of in-progress
     * foreground time for the current app. Resets first when the date has rolled over.
     */
    fun snapshot(nowMs: Long, today: LocalDate = LocalDate.now()): Map<String, Int> =
        synchronized(lock) {
            resetIfNewDayLocked(today)
            val map = HashMap(storedMinutes)
            currentPkg?.let { cur ->
                val add = gapMinutes(nowMs - currentSinceMs)
                if (add > 0) map.merge(cur, add) { a, b -> a + b }
            }
            map
        }

    /** Clears the counters when [today] differs from the counter day (no-op otherwise). */
    fun resetIfNewDay(today: LocalDate = LocalDate.now()) = synchronized(lock) {
        resetIfNewDayLocked(today)
    }

    private fun resetIfNewDayLocked(today: LocalDate) {
        if (counterDay != today) {
            storedMinutes.clear()
            currentPkg = null
            counterDay = today
        }
    }

    private fun gapMinutes(gapMs: Long): Int =
        (gapMs.coerceAtLeast(0L) / 60_000L).toInt().coerceIn(0, MAX_GAP_MINUTES)

    companion object {
        /** Cap applied to a single foreground gap (screen-off gaps are not usage). */
        const val MAX_GAP_MINUTES: Int = 5
    }
}
