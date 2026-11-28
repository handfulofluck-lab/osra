package com.familyshield.agent.security

/**
 * Pure policy for [UnboundTamperWatch] (osra-security#78).
 *
 * When [com.familyshield.agent.services.AccessibilityMonitorService] is running and bound,
 * window-content classification in [TamperScreenPolicy.classify] owns the tamper guard and this
 * fallback stays completely dormant (`shouldMonitor == false`).
 *
 * When a paired, setup-completed device has `AccessibilityMonitorService.isRunning == false` while
 * holding overlay + usage-access grants, foreground-service [android.app.usage.UsageEvents] polling
 * still observes the latest `ACTIVITY_RESUMED` component. This policy gates the dedicated
 * device-admin sheet (while our admin is active), the package-installer uninstaller, and the
 * App-info detail classes behind [TamperGuardTaskActivity], while deliberately leaving the
 * Accessibility settings hub and service toggle pages ungated so a parent can re-bind the service.
 */
object UnboundTamperPolicy {

    /** Polling interval only while the degraded unbound fallback is active and the screen is interactive. */
    const val POLL_INTERVAL_MS: Long = 600L

    /** Idle check cadence while Accessibility is bound or the screen is off. */
    const val DORMANT_CHECK_MS: Long = 5_000L

    /** Lookback window on fallback activation so a screen opened right before process revival is caught. */
    const val INITIAL_LOOKBACK_MS: Long = 60_000L

    /** Small cursor overlap between consecutive `UsageStatsManager.queryEvents` polls. */
    const val QUERY_OVERLAP_MS: Long = 250L

    /** `UsageEvents.Event.ACTIVITY_RESUMED` (API 29+, value 1, same as `MOVE_TO_FOREGROUND`). */
    const val EVENT_ACTIVITY_RESUMED: Int = 1

    data class ResumedEvent(
        val packageName: String?,
        val className: String?,
        val timestampMs: Long,
        val eventType: Int = EVENT_ACTIVITY_RESUMED,
    )

    data class TopActivity(
        val packageName: String,
        val className: String?,
        val timestampMs: Long,
    )

    fun shouldMonitor(
        paired: Boolean,
        setupCompletedOnce: Boolean,
        pinConfigured: Boolean,
        consentPaused: Boolean,
        accessibilityBound: Boolean,
        canDrawOverlays: Boolean,
        usageAccessGranted: Boolean,
        interactive: Boolean,
    ): Boolean =
        paired &&
            setupCompletedOnce &&
            pinConfigured &&
            !consentPaused &&
            !accessibilityBound &&
            canDrawOverlays &&
            usageAccessGranted &&
            interactive

    /**
     * Advances [previous] using a chronological stream of usage [events], keeping the latest
     * `ACTIVITY_RESUMED` transition (ties broken in favour of the later event in the stream).
     */
    fun latestResumedActivity(
        previous: TopActivity?,
        events: Iterable<ResumedEvent>,
    ): TopActivity? {
        var current = previous
        for (event in events) {
            if (event.eventType != EVENT_ACTIVITY_RESUMED) continue
            val pkg = event.packageName?.takeIf { it.isNotBlank() } ?: continue
            if (current == null || event.timestampMs >= current.timestampMs) {
                current = TopActivity(
                    packageName = pkg,
                    className = event.className?.takeIf { it.isNotBlank() },
                    timestampMs = event.timestampMs,
                )
            }
        }
        return current
    }

    /**
     * Classifies a resumed top activity from `(packageName, className)` alone when Accessibility
     * window text is unavailable.
     */
    fun classifyUnboundTop(
        top: TopActivity?,
        ownPackage: String,
        ourAdminActive: Boolean,
    ): TamperScreen {
        if (top == null) return TamperScreen.NONE
        if (top.packageName == ownPackage) return TamperScreen.NONE
        if (top.packageName !in TamperScreenPolicy.SYSTEM_PACKAGES) return TamperScreen.NONE
        val simple = TamperScreenPolicy.simpleName(top.className) ?: return TamperScreen.NONE
        if (simple in TamperScreenPolicy.NEVER_CLASSES) return TamperScreen.NONE
        return when (simple) {
            in TamperScreenPolicy.ADMIN_CLASSES ->
                if (ourAdminActive) TamperScreen.DEACTIVATE_ADMIN else TamperScreen.NONE
            in TamperScreenPolicy.UNINSTALL_CLASSES -> TamperScreen.UNINSTALL
            in TamperScreenPolicy.APP_INFO_CLASSES -> TamperScreen.APP_INFO
            else -> TamperScreen.NONE
        }
    }

    fun shouldLaunchPinGate(
        screen: TamperScreen,
        pinConfigured: Boolean,
        nowMs: Long,
        graceUntilMs: Long,
        sanctionedUntilMs: Long,
        gateSuppressed: Boolean,
    ): Boolean {
        if (screen == TamperScreen.NONE) return false
        if (!pinConfigured) return false
        if (nowMs < graceUntilMs || nowMs < sanctionedUntilMs) return false
        if (gateSuppressed) return false
        return true
    }
}
