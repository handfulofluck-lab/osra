package com.familyshield.agent.vpn

import android.content.Context
import android.content.Intent
import android.content.SharedPreferences
import android.util.Log
import android.os.SystemClock
import com.familyshield.agent.data.AgentSettings
import com.familyshield.agent.data.ConsentState

/**
 * Plain-prefs state of the sinkhole (plan 1.4): which mode the parent last asked for (so the boot
 * receiver and a re-launch restore it), whether the tunnel is currently established, and any
 * unresolved revocation of a filter that had been running under active consent.
 */
object VpnState {
    private const val PREFS = "osra_vpn_state"
    private const val KEY_MODE = "mode"
    private const val KEY_ESTABLISHED = "established"
    private const val KEY_ENABLED = "enabled"
    private const val KEY_FILTER_LOSS_EPOCH = "filter_loss_consent_epoch"
    private const val TAG = "VpnState"
    private const val OWN_CONSENT_TIMEOUT_MS = 120_000L
    @Volatile private var ownConsentUntilMs = 0L

    fun beginOwnConsent() {
        ownConsentUntilMs = SystemClock.elapsedRealtime() + OWN_CONSENT_TIMEOUT_MS
    }

    fun endOwnConsent() {
        ownConsentUntilMs = 0L
    }

    fun hasPendingOwnConsent(): Boolean = SystemClock.elapsedRealtime() < ownConsentUntilMs

    /** Package-scoped signal for a running monitor to re-read the loss state. */
    const val ACTION_FILTER_LOSS_CHANGED = "com.familyshield.agent.action.FILTER_LOSS_CHANGED"

    fun mode(context: Context): String = prefs(context).getString(KEY_MODE, FilterVpnService.MODE_DNS) ?: FilterVpnService.MODE_DNS
    fun setMode(context: Context, mode: String) = prefs(context).edit().putString(KEY_MODE, mode).apply()

    fun isEstablished(context: Context): Boolean = prefs(context).getBoolean(KEY_ESTABLISHED, false)
    fun setEstablished(context: Context, v: Boolean) = prefs(context).edit().putBoolean(KEY_ESTABLISHED, v).apply()

    @Synchronized
    fun isFilterLost(context: Context, settings: AgentSettings, consent: ConsentState): Boolean {
        val epoch = consent.pauseEpoch()
        return FilterLossPolicy.isLost(
            lossEpoch(prefs(context)), isEnabled(context), settings.isPairedSync(), consent.isPaused(), epoch,
        )
    }

    /** Returns true once per incident so the caller enqueues one alert. */
    @Synchronized
    internal fun recordFilterLoss(
        context: Context,
        settings: AgentSettings,
        consent: ConsentState,
        wasEstablished: Boolean,
    ): Boolean {
        val prefs = prefs(context)
        val epoch = consent.pauseEpoch()
        val shouldRecord = FilterLossPolicy.shouldRecord(
            recordedEpoch = lossEpoch(prefs),
            wasEstablished = wasEstablished,
            enabled = isEnabled(context),
            paired = settings.isPairedSync(),
            consentPaused = consent.isPaused(),
            consentEpoch = epoch,
        )
        if (!shouldRecord) return false

        val persisted = prefs.edit().putLong(KEY_FILTER_LOSS_EPOCH, epoch).commit()
        if (!persisted) Log.w(TAG, "Could not persist filter loss")
        notifyFilterLossChanged(context)
        return true
    }

    @Synchronized
    fun clearFilterLoss(context: Context) {
        val prefs = prefs(context)
        if (!prefs.contains(KEY_FILTER_LOSS_EPOCH)) return
        val persisted = prefs.edit().remove(KEY_FILTER_LOSS_EPOCH).commit()
        if (!persisted) Log.w(TAG, "Could not persist filter loss clearance")
        notifyFilterLossChanged(context)
    }

    /** Set once the parent granted VPN consent during onboarding; the filter is restarted on boot while true. */
    fun isEnabled(context: Context): Boolean = prefs(context).getBoolean(KEY_ENABLED, false)

    @Synchronized
    fun setEnabled(context: Context, v: Boolean) {
        prefs(context).edit().putBoolean(KEY_ENABLED, v).apply()
        if (!v) clearFilterLoss(context)
    }

    private fun lossEpoch(prefs: SharedPreferences): Long? =
        prefs.getLong(KEY_FILTER_LOSS_EPOCH, -1L).takeIf { it >= 0L }

    private fun notifyFilterLossChanged(context: Context) {
        context.sendBroadcast(Intent(ACTION_FILTER_LOSS_CHANGED).setPackage(context.packageName))
    }

    private fun prefs(context: Context) = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
}
