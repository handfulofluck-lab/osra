package com.familyshield.agent.enforcement

import android.content.Context

/**
 * #830: one record per lock period for the parent's activity report, decided by Claude on the issue —
 * information, not an alert. A period opens when a locking command sets [LockState] and closes when the
 * parent unlocks/resumes; each overlay raise while it is open is one attempt (a child poking at it).
 *
 * Plain SharedPreferences, like [LockState]: the values are times, a mode and a count, not secrets. A
 * period that is still open when the process dies is returned by the next [start] with no end time, so
 * the row is reported rather than lost.
 */
object LockPeriodTracker {
    private const val PREFS = "osra_lock_period"
    private const val KEY_START = "started_at_ms"
    private const val KEY_MODE = "mode"
    private const val KEY_ATTEMPTS = "attempts"

    data class Period(val startedAtMs: Long, val mode: String, val attempts: Int, val endedAtMs: Long?)

    /** The period that was still open, if any. [start] returns it so a caller can report it. */
    // Hydrogen's #836 note: these are read-modify-write on SharedPreferences from the filter's worker
    // pool; @Synchronized keeps one period's start/attempt/end from interleaving inside this process.
    @Synchronized
    fun start(context: Context, mode: String, nowMs: Long = System.currentTimeMillis()): Period? {
        val open = open(context)
        val prefs = prefs(context)
        prefs.edit().putLong(KEY_START, nowMs).putString(KEY_MODE, mode).putInt(KEY_ATTEMPTS, 0).apply()
        return open
    }

    /** Counts one overlay raise while a period is open; a no-op otherwise. */
    @Synchronized
    fun attempt(context: Context) {
        val prefs = prefs(context)
        val started = prefs.getLong(KEY_START, 0L)
        if (started <= 0L) return
        prefs.edit().putInt(KEY_ATTEMPTS, prefs.getInt(KEY_ATTEMPTS, 0) + 1).apply()
    }

    /**
     * S2 (osra-security#39): the stored period belongs to one enrolment. A re-pair or an unlink that leaves
     * it behind lets the next child's first lock read the previous child's open period and upload it as
     * theirs — a cross-enrolment leak, not a cosmetic stale row.
     */
    @Synchronized
    fun clear(context: Context) {
        prefs(context).edit().clear().apply()
    }

    /** Closes the open period and returns it; null when there was none. */
    @Synchronized
    fun end(context: Context, nowMs: Long = System.currentTimeMillis()): Period? {
        val open = open(context)
        prefs(context).edit().clear().apply()
        return open?.copy(endedAtMs = nowMs)
    }

    /** The activity-event payload for one period (#830); pure, so it is JVM-tested. */
    fun payload(period: Period, iso: (Long) -> String = { java.time.Instant.ofEpochMilli(it).toString() }): Map<String, Any?> =
        buildMap {
            put("startedAt", iso(period.startedAtMs))
            put("endedAt", period.endedAtMs?.let(iso))
            put("attempts", period.attempts)
            put("mode", period.mode)
        }

    private fun open(context: Context): Period? {
        val prefs = prefs(context)
        val started = prefs.getLong(KEY_START, 0L)
        if (started <= 0L) return null
        return Period(
            startedAtMs = started,
            mode = prefs.getString(KEY_MODE, LockState.MODE_NONE) ?: LockState.MODE_NONE,
            attempts = prefs.getInt(KEY_ATTEMPTS, 0),
            endedAtMs = null,
        )
    }

    private fun prefs(context: Context) = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
}
