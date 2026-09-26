package com.familyshield.agent.receivers

import android.content.ComponentName
import android.content.Context
import android.provider.Settings
import com.familyshield.agent.data.AgentSettings
import com.familyshield.agent.network.ApiService
import com.familyshield.agent.network.dto.AlertDto
import com.familyshield.agent.services.AccessibilityMonitorService

/**
 * Feature #19 tamper: accessibility-service-disabled detection. Settings.Secure carries no
 * broadcast for ACCESSIBILITY_ENABLED changes, so this is NOT a BroadcastReceiver — it is polled
 * from LocationService's 60 s loop (see [checkOnce]) and fire-and-forget HMAC-POSTs a critical
 * tamper alert when the OSRA accessibility service is no longer effectively enabled while
 * the device is paired (1 h per-type throttle, see [AlertThrottlePolicy]).
 */
class AccessibilityOffReceiver {

    /**
     * Reads the Secure settings, and when the service is missing while paired, throttle-checks
     * and posts the tamper alert. Timestamp is recorded only on POST success so a failed call
     * does not throttle the retry.
     */
    suspend fun checkOnce(context: Context, api: ApiService, settings: AgentSettings, nowMs: Long) {
        val enabled = Settings.Secure.getString(context.contentResolver, Settings.Secure.ACCESSIBILITY_ENABLED)
        val services = Settings.Secure.getString(context.contentResolver, Settings.Secure.ENABLED_ACCESSIBILITY_SERVICES)
        val component = ComponentName(context, AccessibilityMonitorService::class.java).flattenToString()
        if (!AccessibilityOffPolicy.isTamperState(enabled, services, component)) return
        if (!AlertThrottlePolicy.shouldAlert(settings.tamperAlertTimestamp(AccessibilityOffPolicy.TYPE), nowMs)) return
        val childId = settings.childId() ?: return
        runCatching {
            api.postInternalAlert(
                AlertDto(
                    childId = childId,
                    deviceId = settings.deviceId(),
                    severity = "critical",
                    category = "tamper",
                    title = "Protection was disabled",
                    body = "The OSRA accessibility service was turned off on this device",
                    metadata = mapOf("type" to AccessibilityOffPolicy.TYPE),
                ),
            )
        }.onSuccess {
            settings.recordTamperAlert(AccessibilityOffPolicy.TYPE, nowMs)
        }
    }
}

/** Pure parsing/decision half of the #19 check (JVM-testable, no Android framework). */
object AccessibilityOffPolicy {

    /** Detection type; doubles as the per-type throttle key segment. */
    const val TYPE: String = "accessibility"

    /** Matches one flattened component `pkg/pkg.Class` inside ENABLED_ACCESSIBILITY_SERVICES. */
    private val COMPONENT_REGEX = Regex("([A-Za-z0-9_.$-]+/[A-Za-z0-9_.$-]+)")

    /**
     * True when the service identified by flattened [component] appears in the
     * ENABLED_ACCESSIBILITY_SERVICES value. Entries are `pkg/pkg.Class[:subId]` strings joined
     * by ':' — a naive split(':') breaks on the separator inside each flattened name and on
     * multi-colon entries, so the pair scan matches `pkg/Class` directly and tolerates a
     * colon-suffixed variant of our own component.
     */
    fun isServiceEnabled(enabledServices: String?, component: String): Boolean {
        if (enabledServices.isNullOrBlank()) return false
        return COMPONENT_REGEX.findAll(enabledServices).any { match ->
            val entry = match.value
            entry == component || entry.startsWith("$component:") || component.startsWith("$entry:")
        }
    }

    /** True when the service is effectively enabled: global switch on AND our component listed. */
    fun isEffectivelyEnabled(accessibilityEnabled: String?, enabledServices: String?, component: String): Boolean =
        accessibilityEnabled == "1" && isServiceEnabled(enabledServices, component)

    /** True when paired protection has been tampered with (inverse of [isEffectivelyEnabled]). */
    fun isTamperState(accessibilityEnabled: String?, enabledServices: String?, component: String): Boolean =
        !isEffectivelyEnabled(accessibilityEnabled, enabledServices, component)
}
