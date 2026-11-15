package com.familyshield.agent.receivers

import android.content.ComponentName
import android.content.Context
import android.provider.Settings
import com.familyshield.agent.data.AgentSettings
import com.familyshield.agent.network.ApiService
import com.familyshield.agent.network.dto.AlertDto
import com.familyshield.agent.security.AccessibilityServiceListPolicy
import com.familyshield.agent.security.TamperAlertDedupe
import com.familyshield.agent.security.TamperState
import com.familyshield.agent.security.PermissionObservationPolicy
import com.familyshield.agent.services.AccessibilityMonitorService

/**
 * Feature #19 tamper: accessibility-service-disabled detection. Settings.Secure carries no
 * broadcast for ACCESSIBILITY_ENABLED changes, so this is NOT a BroadcastReceiver — it is polled
 * from LocationService's 60 s loop (see [checkOnce]) and fire-and-forget HMAC-POSTs a critical
 * tamper alert when the OSRA accessibility service goes from recorded-on to off while the device is
 * paired (1 h per-type throttle, see [AlertThrottlePolicy]).
 *
 * Issue #225: "off" alone is not tamper. A fresh install spends setup with the service off, and the
 * first poll there used to page the parent with a protection they had never granted. The alert is
 * now a true -> false edge over a persisted observation (see [AccessibilityOffPolicy.shouldAlertOnObservation]).
 */
class AccessibilityOffReceiver {

    /**
     * Reads the Secure settings, and when the service has just transitioned off while paired,
     * throttle-checks and posts the tamper alert. The new observation is recorded even when no alert
     * is raised; the off state is recorded only after a successful POST so a failed call retries.
     */
    suspend fun checkOnce(context: Context, api: ApiService, settings: AgentSettings, nowMs: Long) {
        val enabled = Settings.Secure.getString(context.contentResolver, Settings.Secure.ACCESSIBILITY_ENABLED)
        val services = Settings.Secure.getString(context.contentResolver, Settings.Secure.ENABLED_ACCESSIBILITY_SERVICES)
        val component = ComponentName(context, AccessibilityMonitorService::class.java).flattenToString()
        val enabledNow = AccessibilityOffPolicy.isEffectivelyEnabled(enabled, services, component)
        // osra-security#29 review (Claude): this poll is the *other* reporter of the same event. A parent who turned
        // the service off inside the PIN's grace window, and a phone that was never paired, must be recorded without
        // paging — which is what the unbind alert already does.
        // Antigravity's exact replacement: the observation check first (so an "on" observation is recorded as on),
        // then the switch-off moment, then the decision — which reads that moment, not the clock.
        if (!AccessibilityOffPolicy.shouldAlertOnObservation(settings.accessibilityWasEnabled(), enabledNow)) {
            settings.recordAccessibilityEnabled(enabledNow)
            return
        }
        val eventAtMs = AccessibilityOffPolicy.eventTimeMs(TamperState.accessibilityDisabledAtMs(context), nowMs)
        if (!AccessibilityOffPolicy.shouldTellParent(settings.isPairedSync(), TamperState.graceUntil(context), eventAtMs)) {
            settings.recordAccessibilityEnabled(false)
            return
        }
        // The edge is real. If the type is throttled, record it off: this event was already reported
        // inside the window, and leaving it "on" would repeat the alert when the window expires.
        if (!AlertThrottlePolicy.shouldAlert(settings.tamperAlertTimestamp(AccessibilityOffPolicy.TYPE), nowMs)) {
            settings.recordAccessibilityEnabled(false)
            return
        }
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
                    // Antigravity's fix: the same key the unbind alert uses for this switch-off, so the server sees
                    // one alert rather than one keyed and one unkeyed page.
                    dedupeKey = TamperAlertDedupe.accessibilityOffKey(settings.deviceId(), eventAtMs),
                ),
            )
        }.onSuccess {
            settings.recordAccessibilityEnabled(false)
            settings.recordTamperAlert(AccessibilityOffPolicy.TYPE, nowMs)
        }
    }
}

/** Pure parsing/decision half of the #19 check (JVM-testable, no Android framework). */
object AccessibilityOffPolicy {

    /** Detection type; doubles as the per-type throttle key segment. */
    const val TYPE: String = "accessibility"

    /**
     * osra-security#29 review (Claude): whether an unbind or a poll observation should reach the parent at all.
     *
     * Not on a phone that was never paired — nobody to tell — and not inside the PIN grace window: a parent who
     * turned the service off after entering the PIN did what they meant to do, and paging them for it is noise
     * that trains a family to ignore the one alert that matters. Pure, because this is the decision a test has to
     * be able to drive.
     */
    /**
     * The moment of the switch-off, as one pure function: the stamped time when the service has one, and "now"
     * otherwise. Both reporters and the grace decision use it, and a row goes red if the stamp is ignored.
     */
    fun eventTimeMs(disabledAtMs: Long, nowMs: Long): Long = if (disabledAtMs > 0L) disabledAtMs else nowMs

    fun shouldTellParent(paired: Boolean, graceUntilMs: Long, nowMs: Long): Boolean =
        paired && nowMs >= graceUntilMs

    /**
     * The grant latch for a PermissionController visit (osra-security#30 review): latched from the grant when a
     * PermissionController window is entered, cleared when any other window is entered, and left alone when the
     * window cannot be named.
     */
    /**
     * Part 2's latch (osra-security#29 review, Antigravity's item 3): the special-access set is captured on
     * **entering** Settings and dropped on leaving it — including when a window of our own package opens, which is
     * what happens when a parent finishes granting and presses Back into OSRA.
     */
    fun nextSpecialAccessLatch(
        previous: Set<com.familyshield.agent.security.TamperScreenPolicy.SpecialAccess>?,
        packageName: String?,
        settingsPackage: String,
        ourPackage: String,
        heldNow: () -> Set<com.familyshield.agent.security.TamperScreenPolicy.SpecialAccess>,
    ): Set<com.familyshield.agent.security.TamperScreenPolicy.SpecialAccess>? = when {
        packageName == null -> previous
        packageName == settingsPackage -> previous ?: heldNow()
        packageName == ourPackage -> null
        else -> null
    }

    fun nextLatch(previous: Boolean?, packageName: String?, grantedNow: () -> Boolean): Boolean? = when {
        packageName == null -> previous
        packageName.contains("permissioncontroller") -> previous ?: grantedNow()
        else -> null
    }

    /**
     * True when the service identified by flattened [component] appears in the
     * ENABLED_ACCESSIBILITY_SERVICES value. Entries are `pkg/pkg.Class[:subId]` strings joined
     * by ':'; [AccessibilityServiceListPolicy] parses each entry the way
     * `ComponentName.unflattenFromString` does, so both the fully-qualified and the short
     * `pkg/.Class` form match (issue #225).
     */
    fun isServiceEnabled(enabledServices: String?, component: String): Boolean =
        AccessibilityServiceListPolicy.isEnabled(enabledServices, component)

    /** True when the service is effectively enabled: global switch on AND our component listed. */
    fun isEffectivelyEnabled(accessibilityEnabled: String?, enabledServices: String?, component: String): Boolean =
        accessibilityEnabled == "1" && isServiceEnabled(enabledServices, component)

    /** True when paired protection has been tampered with (inverse of [isEffectivelyEnabled]). */
    fun isTamperState(accessibilityEnabled: String?, enabledServices: String?, component: String): Boolean =
        !isEffectivelyEnabled(accessibilityEnabled, enabledServices, component)

    /**
     * Issue #225: the accessibility-off alert is an edge, not a level. It is raised only when the
     * service was previously recorded **on** and is off now. `wasEnabled = null` means it has never
     * been observed on, so a first check that finds it off — a fresh install, before setup granted
     * it — is silent instead of paging the parent about a protection they never had. The rule lives
     * in [PermissionObservationPolicy] and is shared with the overlay check.
     */
    fun shouldAlertOnObservation(wasEnabled: Boolean?, isEnabledNow: Boolean): Boolean =
        PermissionObservationPolicy.shouldAlertOnObservation(wasEnabled, isEnabledNow)
}
