package com.familyshield.agent.security

/**
 * Pure policy for [UnboundTamperWatch] (osra-security#78).
 *
 * When [com.familyshield.agent.services.AccessibilityMonitorService] is running and bound,
 * window-content classification in [TamperScreenPolicy.classify] owns the tamper guard and this
 * fallback stays completely dormant (`shouldMonitor == false`).
 *
 * When Accessibility is unbound on a paired, setup-completed device, `UsageStatsManager.queryEvents`
 * exposes only `(packageName, className)` without visible window text or intent extras. Shared
 * multi-app host screens (`ADMIN_CLASSES`, `UNINSTALL_CLASSES`, `APP_INFO_CLASSES`) exist for every
 * installed app on the phone, so [classifyUnboundTop] intentionally returns [TamperScreen.NONE] for
 * all shared host screens — keeping unrelated apps' App Info, `DeviceAdminAdd`, and uninstaller
 * flows usable without a PIN overlay. In the unbound state:
 * - OSRA device-admin deactivation (and Uninstall while admin is active) is gated by OSRA's own
 *   [GuardianAdminReceiver.onDisableRequested],
 * - OSRA App-info storage wipe ("Manage space") is gated by `<application android:manageSpaceActivity>`,
 * - OSRA Force-stop / `OneKeyClean` process kill is mitigated by Xiaomi Recents exclusion plus
 *   bounded exit + standing `AlarmManager` / `WorkManager` revival, and
 * - Phone-wide second-space setup screens ([TamperScreenPolicy.SPACE_SETUP_SCREENS]), which have no
 *   per-app target, are covered directly by [classifyUnboundTop].
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
        unlinkPending: Boolean = false,
        setupCompletedOnce: Boolean,
        pinConfigured: Boolean,
        consentPaused: Boolean,
        accessibilityBound: Boolean,
        canDrawOverlays: Boolean,
        usageAccessGranted: Boolean,
        interactive: Boolean,
    ): Boolean =
        paired &&
            !unlinkPending &&
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
     * Classifies a resumed top activity from `UsageEvents` when Accessibility window text is
     * unavailable. Only phone-wide [TamperScreenPolicy.SPACE_SETUP_SCREENS] are gated directly;
     * shared multi-app host classes return [TamperScreen.NONE] so unrelated apps remain usable.
     */
    fun classifyUnboundTop(
        top: TopActivity?,
        ownPackage: String,
    ): TamperScreen {
        if (top == null) return TamperScreen.NONE
        if (top.packageName == ownPackage) return TamperScreen.NONE
        val simple = TamperScreenPolicy.simpleName(top.className)
        if ((top.packageName to simple) in TamperScreenPolicy.SPACE_SETUP_SCREENS) {
            return TamperScreen.SPACE_SETUP
        }
        return TamperScreen.NONE
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
