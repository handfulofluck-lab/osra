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

    fun isRemovalSanctioned(context: Context, nowMs: Long): Boolean =
        nowMs < prefs(context).getLong(KEY_SANCTIONED_UNTIL, 0L)

    /** Last protection tier observed by the agent, so a drop to NONE can be alerted exactly once. */
    fun lastTier(context: Context): String? = prefs(context).getString(KEY_LAST_TIER, null)

    fun setLastTier(context: Context, tier: String) {
        prefs(context).edit().putString(KEY_LAST_TIER, tier).apply()
    }

    private fun prefs(context: Context) =
        context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
}
