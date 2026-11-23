package com.familyshield.agent.receivers

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.util.Log
import com.familyshield.agent.data.AgentSettings
import com.familyshield.agent.data.ConsentState
import com.familyshield.agent.data.WorkScheduler
import com.familyshield.agent.di.WorkerEntryPoint
import com.familyshield.agent.network.ApiService
import com.familyshield.agent.network.dto.AlertDto
import com.familyshield.agent.services.PendingPingWorker
import com.familyshield.agent.vpn.FilterRecoveryPolicy
import com.familyshield.agent.vpn.FilterVpnService
import com.familyshield.agent.vpn.VpnState
import dagger.hilt.android.EntryPointAccessors
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.launch

/**
 * Feature #19 tamper: fires when the agent's own package is replaced and fire-and-forget
 * HMAC-POSTs an informational tamper alert so parents see agent churn on the device. Not
 * throttled — the event fires at most once per actual replace.
 * // NOTE: Android exposes no way to distinguish an update from a sideloaded reinstall here
 * (both come through as ACTION_MY_PACKAGE_REPLACED), so the alert says "reinstalled/updated".
 */
class PackageReplacedReceiver : BroadcastReceiver() {

    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)

    override fun onReceive(context: Context, intent: Intent) {
        // osra-security#8 F6: exported for the system's broadcast, so the one action only.
        if (!BroadcastGate.accepts(Intent.ACTION_MY_PACKAGE_REPLACED, intent.action)) return
        val entryPoint = EntryPointAccessors.fromApplication(context, WorkerEntryPoint::class.java)
        // NOTE: goAsync keeps the broadcast alive for the (best-effort) network call.
        val pending = goAsync()
        scope.launch {
            try {
                handleReplace(
                    context,
                    entryPoint.apiService(),
                    entryPoint.agentSettings(),
                    entryPoint.consentState(),
                )
            } finally {
                pending.finish()
            }
        }
    }

    /** Restores web filter / periodic workers and posts the tamper alert when genuinely replaced. */
    private suspend fun handleReplace(
        context: Context,
        api: ApiService,
        settings: AgentSettings,
        consent: ConsentState,
    ) {
        if (!settings.isPaired()) return
        // osra-security#8 F6: only when our own package really was replaced just now, not on a sent intent.
        if (!BroadcastGate.genuineSelfReplace(ownFacts(context), System.currentTimeMillis())) {
            Log.w(TAG, "MY_PACKAGE_REPLACED without a recent update; no alert or recovery")
            return
        }
        // #934: an app update kills the old process without running FilterVpnService.onDestroy(), leaving
        // stale established=true on disk and the tunnel down. Clear stale state and restore protection.
        if (FilterVpnService.tunnelMode == null) {
            VpnState.setEstablished(context, false)
        }
        runCatching {
            WorkScheduler.scheduleAll(context)
            PendingPingWorker.schedule(context)
        }.onFailure { Log.w(TAG, "rescheduling work after update failed", it) }

        if (
            FilterRecoveryPolicy.shouldRestartAfterUpdate(
                isPaired = settings.isPaired(),
                vpnEnabled = VpnState.isEnabled(context),
                vpnPrepared = FilterVpnService.isPrepared(context),
                consentPaused = consent.isPaused(),
                filterLost = VpnState.isFilterLost(context, settings, consent),
                liveTunnelMode = FilterVpnService.tunnelMode,
            )
        ) {
            runCatching { FilterVpnService.start(context) }
                .onFailure { Log.w(TAG, "restarting FilterVpnService after update failed", it) }
        }

        val childId = settings.childId() ?: return
        runCatching {
            api.postInternalAlert(
                AlertDto(
                    childId = childId,
                    deviceId = settings.deviceId(),
                    severity = "info",
                    category = "tamper",
                    title = "Agent updated",
                    body = "OSRA agent was reinstalled/updated",
                    metadata = mapOf("type" to "replaced"),
                ),
            )
        }
    }

    @Suppress("DEPRECATION") // flag-based getPackageInfo is deprecated at 33 but valid ≥26
    private fun ownFacts(context: Context): BroadcastGate.PackageFacts? = runCatching {
        val info = context.packageManager.getPackageInfo(context.packageName, 0)
        BroadcastGate.PackageFacts(firstInstallMs = info.firstInstallTime, lastUpdateMs = info.lastUpdateTime)
    }.getOrNull()

    private companion object {
        const val TAG = "PackageReplacedReceiver"
    }
}
