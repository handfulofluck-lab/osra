package com.familyshield.agent.vpn

import android.content.Context

/**
 * Plain-prefs state of the sinkhole (plan 1.4): which mode the parent last asked for (so the boot
 * receiver and a re-launch restore it), whether the tunnel is currently established, and when it was
 * last revoked. Readable from receivers before any encrypted store is open.
 */
object VpnState {
    private const val PREFS = "osra_vpn_state"
    private const val KEY_MODE = "mode"
    private const val KEY_ESTABLISHED = "established"
    private const val KEY_REVOKED_AT = "revoked_at"
    private const val KEY_ENABLED = "enabled"

    fun mode(context: Context): String = prefs(context).getString(KEY_MODE, FilterVpnService.MODE_DNS) ?: FilterVpnService.MODE_DNS
    fun setMode(context: Context, mode: String) = prefs(context).edit().putString(KEY_MODE, mode).apply()

    fun isEstablished(context: Context): Boolean = prefs(context).getBoolean(KEY_ESTABLISHED, false)
    fun setEstablished(context: Context, v: Boolean) = prefs(context).edit().putBoolean(KEY_ESTABLISHED, v).apply()

    fun revokedAt(context: Context): Long = prefs(context).getLong(KEY_REVOKED_AT, 0L)
    fun setRevokedAt(context: Context, ms: Long) = prefs(context).edit().putLong(KEY_REVOKED_AT, ms).apply()

    /** Set once the parent granted VPN consent during onboarding; the filter is restarted on boot while true. */
    fun isEnabled(context: Context): Boolean = prefs(context).getBoolean(KEY_ENABLED, false)
    fun setEnabled(context: Context, v: Boolean) = prefs(context).edit().putBoolean(KEY_ENABLED, v).apply()

    private fun prefs(context: Context) = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
}
