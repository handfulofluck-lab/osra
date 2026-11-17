package com.familyshield.agent.telemetry

import android.content.Context
import android.os.SystemClock
import android.provider.Settings
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
 *
 * **The instant alone is not enough (#884 review).** `elapsedRealtime()` is monotonic but
 * `currentTimeMillis()` is not, so moving the phone's clock moves this value with no restart — a child
 * could fabricate one alert per telemetry tick. The platform has a counter for the job, which is why
 * [bootCountNow] is sent beside it: the server decides a restart from the count when it has one, and
 * uses the instant only for the time and gap it shows.
 */
object BootClock {
    fun bootedAtIso(nowMs: Long, elapsedRealtimeMs: Long): String =
        Instant.ofEpochMilli(nowMs - elapsedRealtimeMs)
            .truncatedTo(ChronoUnit.SECONDS)
            .toString()

    /** The same value for this moment, read from the system clocks. */
    fun bootedAtIsoNow(): String = bootedAtIso(System.currentTimeMillis(), SystemClock.elapsedRealtime())

    /**
     * `Settings.Global.BOOT_COUNT` is a literal here, not the platform constant: that constant is API 24
     * and the read below behaves the same on every version (a device without the setting answers the
     * default). No permission is involved — this is a public setting.
     */
    private const val BOOT_COUNT_KEY = "boot_count"

    /** The platform's boot counter, or null when it is absent or negative (unknown). */
    fun bootCountOrNull(raw: Int): Int? = raw.takeIf { it >= 0 }

    /**
     * The boot counter for this moment. Null when the platform does not expose it: `-1` is
     * `Settings.Global.getInt`'s "missing" answer, and a read that throws costs the field rather than the
     * telemetry upload — the server then falls back to the instant, which is what the agent sent before
     * this field existed.
     */
    fun bootCountNow(context: Context): Int? =
        runCatching { Settings.Global.getInt(context.contentResolver, BOOT_COUNT_KEY, -1) }
            .getOrNull()
            ?.let(::bootCountOrNull)
}
