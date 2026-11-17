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

    /** #830: true when a site alert may be posted again — the first time, or after the quiet window. */
    fun siteAlertDue(lastPostMs: Long?, nowMs: Long, quietMs: Long): Boolean =
        lastPostMs == null || nowMs - lastPostMs >= quietMs
}

object AttemptCounter {

    private const val PREFS = "osra_block_attempts"

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
