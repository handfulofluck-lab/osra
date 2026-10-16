package com.familyshield.agent.security

import android.content.Context

/**
 * Tiny persisted flag set by [FamilyShieldDeviceAdmin.onDisabled] and read by the tamper check, so a
 * device-admin removal survives the process death that often follows it and still reaches the parent
 * as an alert on the next poll. Not a secret (a boolean), so plain SharedPreferences is fine.
 */
object TamperState {
    private const val PREFS = "osra_tamper_state"
    private const val KEY_ADMIN_DISABLED_PENDING = "admin_disabled_pending"

    fun setAdminDisabledPending(context: Context, pending: Boolean) {
        prefs(context).edit().putBoolean(KEY_ADMIN_DISABLED_PENDING, pending).apply()
    }

    fun isAdminDisabledPending(context: Context): Boolean =
        prefs(context).getBoolean(KEY_ADMIN_DISABLED_PENDING, false)

    private fun prefs(context: Context) =
        context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
}
