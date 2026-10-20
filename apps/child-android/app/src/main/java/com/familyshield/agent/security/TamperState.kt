package com.familyshield.agent.security

import android.content.Context

/**
 * Tiny persisted flag set by [GuardianAdminReceiver.onDisabled] and read by the tamper check, so a
 * device-admin removal survives the process death that often follows it and still reaches the parent
 * as an alert on the next poll. Not a secret (a boolean), so plain SharedPreferences is fine.
 */
object TamperState {
    private const val PREFS = "osra_tamper_state"
    private const val KEY_ADMIN_DISABLED_PENDING = "admin_disabled_pending"
    private const val KEY_ADMIN_DISABLED_AT_MS = "admin_disabled_at_ms"
    private const val KEY_ADMIN_ALERTS_POSTED = "admin_alerts_posted"
    private const val KEY_GRACE_UNTIL = "guard_grace_until_ms"
    private const val KEY_LAST_TIER = "last_tier"
    private const val KEY_SANCTIONED_UNTIL = "sanctioned_removal_until_ms"
    private const val KEY_ADMIN_REMOVED_BY_PARENT = "admin_removed_by_parent"
    private const val KEY_GUARD_WINDOW_START_MS = "guard_window_start_ms"
    private const val KEY_GUARD_WINDOW_COUNT = "guard_window_count"

    /** How many accepted dedupe keys are kept; a retry only ever needs the newest one. */
    private const val MAX_POSTED_KEYS = 4

    fun setAdminDisabledPending(context: Context, pending: Boolean) {
        prefs(context).edit().putBoolean(KEY_ADMIN_DISABLED_PENDING, pending).apply()
    }

    fun isAdminDisabledPending(context: Context): Boolean =
        prefs(context).getBoolean(KEY_ADMIN_DISABLED_PENDING, false)

    /**
     * Issue #225: the wall-clock time [GuardianAdminReceiver.onDisabled] observed the removal. It is
     * half of the alert's idempotency key, so every retry path (the expedited worker and the 60-s
     * drain) derives the same key for the same deactivation.
     */
    fun adminDisabledAtMs(context: Context): Long =
        prefs(context).getLong(KEY_ADMIN_DISABLED_AT_MS, 0L)

    fun setAdminDisabledAt(context: Context, atMs: Long) {
        prefs(context).edit().putLong(KEY_ADMIN_DISABLED_AT_MS, atMs).apply()
    }

    /** True when the server already accepted an admin-removal alert with this dedupe key (#225). */
    fun isTamperAlertPosted(context: Context, key: String): Boolean =
        prefs(context).getStringSet(KEY_ADMIN_ALERTS_POSTED, emptySet()).orEmpty().contains(key)

    fun markTamperAlertPosted(context: Context, key: String) {
        val current = prefs(context).getStringSet(KEY_ADMIN_ALERTS_POSTED, emptySet()).orEmpty()
        val updated = (current + key).toList().takeLast(MAX_POSTED_KEYS).toSet()
        prefs(context).edit().putStringSet(KEY_ADMIN_ALERTS_POSTED, updated).apply()
    }

    /** Parent verified the PIN: the guard stands down until this wall-clock time (ADR-0010 §3). */
    fun grantGrace(context: Context, untilMs: Long) {
        prefs(context).edit().putLong(KEY_GRACE_UNTIL, untilMs).apply()
    }

    fun graceUntil(context: Context): Long = prefs(context).getLong(KEY_GRACE_UNTIL, 0L)

    /** The parent (PIN verified) is removing admin on purpose: no tamper alert for the next minute. */
    fun markSanctionedRemoval(context: Context, untilMs: Long) {
        prefs(context).edit().putLong(KEY_SANCTIONED_UNTIL, untilMs).apply()
    }

    /** The end of the parent-PIN removal window, or 0 when no removal was ever sanctioned. */
    fun sanctionedRemovalUntil(context: Context): Long =
        prefs(context).getLong(KEY_SANCTIONED_UNTIL, 0L)

    /**
     * True while this app's own parent-PIN removal has not been followed by a successful activation
     * (issue #188). The status screen uses it to explain an alert-only tier instead of claiming a
     * stuck Knox record; [GuardianAdminReceiver.onEnabled] and a protected `enrolmentOutcome()` clear it.
     */
    fun wasAdminRemovedByParent(context: Context): Boolean =
        prefs(context).getBoolean(KEY_ADMIN_REMOVED_BY_PARENT, false)

    fun setAdminRemovedByParent(context: Context, removed: Boolean) {
        prefs(context).edit().putBoolean(KEY_ADMIN_REMOVED_BY_PARENT, removed).apply()
    }

    /** Last protection tier observed by the agent, so a drop to NONE can be alerted exactly once. */
    fun lastTier(context: Context): String? = prefs(context).getString(KEY_LAST_TIER, null)

    fun setLastTier(context: Context, tier: String) {
        prefs(context).edit().putString(KEY_LAST_TIER, tier).apply()
    }

    /**
     * Issue #227: the current remove-protection attempt window, or null when none has opened. The
     * count is persisted before the alert POST so an offline failure cannot lose an attempt; the
     * window start survives process death, and neither value is derived from a screen the child can
     * dismiss.
     */
    fun guardAttemptWindow(context: Context): GuardAttemptWindow.State? {
        val p = prefs(context)
        val start = p.getLong(KEY_GUARD_WINDOW_START_MS, 0L)
        val count = p.getInt(KEY_GUARD_WINDOW_COUNT, 0)
        if (start <= 0L || count <= 0) return null
        return GuardAttemptWindow.State(windowStartMs = start, count = count)
    }

    fun setGuardAttemptWindow(context: Context, window: GuardAttemptWindow.State) {
        prefs(context).edit()
            .putLong(KEY_GUARD_WINDOW_START_MS, window.windowStartMs)
            .putInt(KEY_GUARD_WINDOW_COUNT, window.count)
            .apply()
    }

    /** A re-pair is a new device enrolment; its first guard attempt opens a fresh window. */
    fun clearGuardAttemptWindow(context: Context) {
        prefs(context).edit()
            .remove(KEY_GUARD_WINDOW_START_MS)
            .remove(KEY_GUARD_WINDOW_COUNT)
            .apply()
    }

    private fun prefs(context: Context) =
        context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
}
