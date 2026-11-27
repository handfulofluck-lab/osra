package com.familyshield.agent.enforcement

import android.content.Context

/**
 * #830: a monotonic attempt count per (namespace, id, UTC day) for the grouped `app_blocked` and
 * `web_threat` alerts.
 *
 * The server only updates the parent's row when the posted `attemptCount` is higher than the stored one
 * (`applyAttemptCount`, atomic via `attemptCount: { lt }`), so the count must survive a process death.
 * A number is not a secret: it lives in plain SharedPreferences, like [LockState] and `VpnState`.
 */
object AlertKeys {
    /** The `app_blocked` dedupe key: one row per app per UTC day (#830). */
    fun blockedApp(pkg: String, day: String): String = "app:$pkg:$day"

    /** The `web_threat` dedupe key: one row per host per UTC day (#830). */
    fun blockedSite(host: String, day: String): String = "domain:$host:$day"

    /** #1128 item 3: 10-minute quiet window for hostless blocked-site alerts when `siteNames` is off. */
    const val REDACTED_SITE_WINDOW_MS: Long = 10 * 60 * 1000L

    /**
     * #1128 item 3: hostless dedupe key per 10-minute UTC window (`web:YYYY-MM-DDTHH:M0`).
     * Keeps repeats inside one quiet window grouped while allowing a new attempt in a later
     * 10-minute window to raise a fresh alert and notify the parent, with zero host data.
     */
    fun redactedBlockedSite(nowMs: Long, windowMs: Long = REDACTED_SITE_WINDOW_MS): String {
        val bucketMs = Math.floorDiv(nowMs, windowMs) * windowMs
        val utc = java.time.Instant.ofEpochMilli(bucketMs).atOffset(java.time.ZoneOffset.UTC)
        return String.format(
            java.util.Locale.US,
            "web:%04d-%02d-%02dT%02d:%02d",
            utc.year,
            utc.monthValue,
            utc.dayOfMonth,
            utc.hour,
            utc.minute,
        )
    }

    /** #1128 item 3: hostless body carrying the running daily count on later blocked-site windows. */
    fun redactedBlockedSiteBody(attempts: Int): String =
        if (attempts > 1) "$attempts blocked sites today." else "Your child tried to open a blocked site."

    /** #830: true when a site alert may be posted again — the first time, or after the quiet window. */
    fun siteAlertDue(lastPostMs: Long?, nowMs: Long, quietMs: Long): Boolean =
        lastPostMs == null || nowMs - lastPostMs >= quietMs
}

object AttemptCounter {

    private const val PREFS = "osra_block_attempts"

    /**
     * S2 (osra-security#39): the counters are keyed by package id and host, not by child, so one left behind
     * on a re-pair is reported against the next child's first blocked app — the previous enrolment's count.
     */
    @Synchronized
    fun clear(context: Context) {
        context.getSharedPreferences(PREFS, Context.MODE_PRIVATE).edit().clear().apply()
    }

    /** The next count for [namespace]:[id] on [day] (`yyyy-MM-dd`, UTC). */
    // Hydrogen's #836 note: read-modify-write under the filter's 4-thread pool could lose a count.
    // @Synchronized serialises it inside this process; the count is grouping metadata, not a secret.
    @Synchronized
    fun next(context: Context, namespace: String, id: String, day: String): Int {
        val prefs = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
        val key = "$namespace|$id|$day"
        val next = (prefs.getInt(key, 0)) + 1
        prefs.edit().putInt(key, next).apply()
        return next
    }
}
