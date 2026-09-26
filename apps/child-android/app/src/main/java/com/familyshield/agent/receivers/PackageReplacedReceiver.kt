package com.familyshield.agent.receivers

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
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
 * Feature #19 tamper: fires when the agent's own package is replaced and fire-and-forget
 * HMAC-POSTs an informational tamper alert so parents see agent churn on the device. Not
 * throttled — the event fires at most once per actual replace.
 * // NOTE: Android exposes no way to distinguish an update from a sideloaded reinstall here
 * (both come through as ACTION_MY_PACKAGE_REPLACED), so the alert says "reinstalled/updated".
 */
class PackageReplacedReceiver : BroadcastReceiver() {

    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)

    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action != Intent.ACTION_MY_PACKAGE_REPLACED) return
        val entryPoint = EntryPointAccessors.fromApplication(context, WorkerEntryPoint::class.java)
        // NOTE: goAsync keeps the broadcast alive for the (best-effort) network call.
        val pending = goAsync()
        scope.launch {
            try {
                alert(entryPoint.apiService(), entryPoint.agentSettings())
            } finally {
                pending.finish()
            }
        }
    }

    /** Posts the tamper alert when the device is paired; errors are logged, never thrown. */
    private suspend fun alert(api: ApiService, settings: AgentSettings) {
        if (!settings.isPaired()) return
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
}
