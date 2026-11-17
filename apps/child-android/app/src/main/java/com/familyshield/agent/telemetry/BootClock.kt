package com.familyshield.agent.telemetry

import android.os.SystemClock
import java.time.Instant
import java.time.temporal.ChronoUnit

/**
 * Issue #867: the instant this device booted, reported as `bootedAt` beside the usage counters.
 *
 * The server has no other way to see a restart. Its silence window is two telemetry intervals (30
 * minutes) because one missed report must not read as a failed phone, while a restart costs one or two
 * minutes — so the status flip can never show it, and lowering the window would trade a silent gap for
 * a false `device_silent`. `SystemClock.elapsedRealtime()` counts since boot *including deep sleep*, so
 * `now - elapsedRealtime` is the boot instant: constant for the life of the boot, different after a
 * restart. The server compares this upload with the one it stored and reports the difference.
 *
 * Truncated to whole seconds: the two clocks advance together, but their millisecond fractions do not,
 * and a value that wobbles by a few milliseconds on every tick would be noise to a comparison whose job
 * is to notice a reboot.
 */
object BootClock {
    fun bootedAtIso(nowMs: Long, elapsedRealtimeMs: Long): String =
        Instant.ofEpochMilli(nowMs - elapsedRealtimeMs)
            .truncatedTo(ChronoUnit.SECONDS)
            .toString()

    /** The same value for this moment, read from the system clocks. */
    fun bootedAtIsoNow(): String = bootedAtIso(System.currentTimeMillis(), SystemClock.elapsedRealtime())
}
