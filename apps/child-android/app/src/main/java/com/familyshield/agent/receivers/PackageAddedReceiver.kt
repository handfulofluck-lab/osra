package com.familyshield.agent.receivers

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import com.familyshield.agent.data.AgentSettings
import com.familyshield.agent.di.WorkerEntryPoint
import com.familyshield.agent.network.ApiService
import com.familyshield.agent.network.dto.AlertDto
import dagger.hilt.android.EntryPointAccessors
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.launch

/**
 * Feature #8 install approval (detect -> alert): on PACKAGE_ADDED for a package that is not our
 * own and not a replace (update), looks up the app label and fire-and-forget HMAC-POSTs an
 * install_request alert to /v1/alerts/internal, throttled to one alert per package per 24 h
 * (DataStore timestamps, see [InstallAlertPolicy]). A parent "deny" from the parent app adds a
 * block rule server-side; this agent then enforces it through the normal rules sync
 * (rules_updated -> RuleRepository), not here.
 * // NOTE: the alert fires after install (Android delivers no pre-install approval broadcast to
 * non-system apps) — approval is retrospective: parent sees the alert and can block the app.
 */
class PackageAddedReceiver : BroadcastReceiver() {

    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)

    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action != Intent.ACTION_PACKAGE_ADDED) return
        val packageId = intent.data?.schemeSpecificPart ?: return
        val replacing = intent.getBooleanExtra(Intent.EXTRA_REPLACING, false)
        val entryPoint = EntryPointAccessors.fromApplication(context, WorkerEntryPoint::class.java)
        // NOTE: goAsync keeps the broadcast alive for the (best-effort) network call.
        val pending = goAsync()
        scope.launch {
            try {
                alertIfNeeded(context, packageId, replacing, entryPoint.apiService(), entryPoint.agentSettings())
            } finally {
                pending.finish()
            }
        }
    }

    /** Throttle-checks, resolves the app label and posts the install_request alert. */
    private suspend fun alertIfNeeded(
        context: Context,
        packageId: String,
        replacing: Boolean,
        api: ApiService,
        settings: AgentSettings,
    ) {
        val last = settings.installAlertTimestamp(packageId)
        if (!InstallAlertPolicy.shouldAlert(packageId, replacing, context.packageName, last, System.currentTimeMillis())) {
            return
        }
        val appName = runCatching { appLabel(context, packageId) }.getOrDefault(packageId)
        val childId = settings.childId() ?: return
        runCatching {
            api.postInternalAlert(
                AlertDto(
                    childId = childId,
                    deviceId = settings.deviceId(),
                    severity = "info",
                    category = "install_request",
                    title = "New app installed",
                    body = "$appName ($packageId) was installed on this device",
                    metadata = mapOf("packageId" to packageId, "appName" to appName),
                ),
            )
        }.onSuccess {
            // NOTE: timestamp recorded only on success so a failed POST does not throttle retries.
            settings.recordInstallAlert(packageId, System.currentTimeMillis())
        }
    }

    /** Resolves the human-readable app label; falls back to the package id on any failure. */
    @Suppress("DEPRECATION") // flag-based getApplicationInfo is deprecated at 33 but valid ≥26
    private fun appLabel(context: Context, packageId: String): String {
        val pm: PackageManager = context.packageManager
        val info = pm.getApplicationInfo(packageId, 0)
        return pm.getApplicationLabel(info).toString()
    }
}
