package com.familyshield.agent.security

import android.app.admin.DeviceAdminReceiver
import android.content.Context
import android.content.Intent
import android.provider.Settings
import android.util.Log
import com.familyshield.agent.di.WorkerEntryPoint
import com.familyshield.agent.recovery.ServiceRecovery
import com.familyshield.agent.services.AccessibilityMonitorService
import com.familyshield.agent.setup.SetupCompletionStore
import dagger.hilt.android.EntryPointAccessors

/**
 * Device Admin receiver (ADR-0010). Being an active admin is what lets the agent block uninstall
 * (the user must clear admin first, which we gate behind the parent PIN) and call `lockNow`.
 *
 * `onDisableRequested` returns the warning the OS shows when the child tries to turn admin off,
 * revives stopped background services (`ServiceRecovery.run`), and launches [TamperGuardTaskActivity]
 * when an unsanctioned deactivation is attempted (osra-security#78). `onDisabled` fires after admin
 * is actually removed — we record it so the next agent poll raises a tamper alert to the parent.
 *
 * The class name is itself operationally significant (issues #202 and #217): Samsung Knox keys its
 * admin registry by **component + user**, and a stale row for a previous component name refuses every
 * new activation through the system sheet with `Admin is already added`. A new component name is not in
 * that registry, so renaming the receiver is the recovery path — and the reason [COMPONENT_CLASS], the
 * manifest entry and `res/xml/device_admin.xml`'s consumer must move together.
 * `AdminReceiverContractTest` pins that.
 *
 * Renamed twice for the same reason: #209 moved `FamilyShieldDeviceAdmin` → `ParentalAdminReceiver`,
 * and #217 moved `ParentalAdminReceiver` → `GuardianAdminReceiver` after `dpm remove-active-admin`
 * stranded a Knox row on the Flip4. The root cause is the cleanup command, not the name — see
 * `docs/TESTING.md` §5, which no longer prescribes that command on a Samsung.
 */
class GuardianAdminReceiver : DeviceAdminReceiver() {

    override fun onEnabled(context: Context, intent: Intent) {
        Log.i(TAG, "device admin enabled")
        TamperState.setAdminDisabledPending(context, false)
        // A re-activation starts a new event; the next disable records its own timestamp.
        TamperState.setAdminDisabledAt(context, 0L)
        // Activation succeeded, so whatever an earlier parent-PIN removal recorded is no longer true.
        TamperState.setAdminRemovedByParent(context, false)
    }

    override fun onDisableRequested(context: Context, intent: Intent): CharSequence {
        val appContext = context.applicationContext
        runCatching { ServiceRecovery.run(appContext) }
            .onFailure { Log.w(TAG, "service recovery on disable request failed", it) }

        runCatching {
            val entry = EntryPointAccessors.fromApplication(appContext, WorkerEntryPoint::class.java)
            val settings = entry.agentSettings()
            val paired = settings.isPairedSync()
            val setupCompleted = SetupCompletionStore.isCompletedForDevice(appContext, settings.deviceIdSync())
            val pinConfigured = entry.parentPinStore().isConfigured()
            val consentPaused = entry.consentState().isPaused()
            val nowMs = System.currentTimeMillis()
            val suppressed = GuardDebouncePolicy.suppress(
                nowMs = nowMs,
                lastGuardMs = lastDisableGuardMs,
                gateShowing = GuardGateState.showing,
                gateResumedSinceLaunch = GuardGateState.resumedSince(lastDisableGuardMs),
                gateMultiWindow = GuardGateState.multiWindow,
            )
            val canLaunch = Settings.canDrawOverlays(appContext) || AccessibilityMonitorService.isRunning
            when (
                AdminDisableRequestPolicy.decide(
                    paired = paired,
                    setupCompletedOnce = setupCompleted,
                    pinConfigured = pinConfigured,
                    consentPaused = consentPaused,
                    nowMs = nowMs,
                    graceUntilMs = TamperState.graceUntil(appContext),
                    sanctionedUntilMs = TamperState.sanctionedRemovalUntil(appContext),
                    gateSuppressed = suppressed,
                    canLaunchFromBackground = canLaunch,
                )
            ) {
                AdminDisableRequestPolicy.Action.ALLOW_WITHOUT_GATE,
                AdminDisableRequestPolicy.Action.ALREADY_COVERED,
                -> Unit

                AdminDisableRequestPolicy.Action.LAUNCH_PIN_GATE,
                AdminDisableRequestPolicy.Action.RECORD_ATTEMPT_AND_BEST_EFFORT_GATE,
                -> {
                    lastDisableGuardMs = nowMs
                    val attempt = GuardAttemptWindow.record(
                        TamperState.guardAttemptWindow(appContext),
                        nowMs,
                        TamperScreen.DEACTIVATE_ADMIN.name.lowercase(),
                    )
                    TamperState.setGuardAttemptWindow(appContext, attempt.state)
                    runCatching {
                        TamperAlertWorker.enqueue(
                            appContext,
                            TamperAlertWorker.TYPE_GUARD_TRIGGERED,
                            detail = "Screen: deactivate_admin in com.android.settings",
                            windowStartMs = attempt.state.windowStartMs,
                            attemptCount = attempt.state.count,
                            screens = attempt.state.screens,
                        )
                    }.onFailure { Log.w(TAG, "could not enqueue disable-request guard alert", it) }

                    runCatching {
                        appContext.startActivity(
                            Intent(appContext, TamperGuardTaskActivity::class.java)
                                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP)
                                .putExtra(TamperGuardActivity.EXTRA_REASON, TamperGuardActivity.REASON_SETTINGS),
                        )
                    }.onFailure { Log.w(TAG, "could not launch TamperGuardTaskActivity on disable request", it) }
                }
            }
        }.onFailure { Log.w(TAG, "onDisableRequested guard handling failed", it) }

        return "Removing OSRA admin turns off the parental-control protections on this device. " +
            "Your parent will be notified."
    }

    override fun onDisabled(context: Context, intent: Intent) {
        val outcome = AdminDisabledPolicy.classify(
            nowMs = System.currentTimeMillis(),
            sanctionedUntilMs = TamperState.sanctionedRemovalUntil(context),
        )
        when (outcome) {
            AdminDisabledOutcome.SANCTIONED_PARENT_REMOVAL -> {
                Log.i(TAG, "device admin disabled by the parent (PIN verified) — no alert")
                TamperState.setLastTier(context, ProtectionTier.NONE.name)
                // The removal is asynchronous: onDisabled is the only place it is confirmed, and the
                // open sanctioned window is what proves the parent asked for it.
                TamperState.setAdminRemovedByParent(context, true)
            }

            AdminDisabledOutcome.TAMPER_ALERT -> {
                // Issue #225: the timestamp is the event identity. Both this enqueue and the 60-s
                // drain derive the same dedupe key from it, so one deactivation posts one alert.
                val disabledAtMs = System.currentTimeMillis()
                Log.w(TAG, "device admin disabled — flagging tamper alert ($disabledAtMs)")
                TamperState.setAdminDisabledAt(context, disabledAtMs)
                // No parent-removal record here: an out-of-band removal stays a tamper alert.
                TamperState.setAdminDisabledPending(context, true)
                // Tell the parent now, not at the next poll: expedited work survives the process
                // death that usually follows an admin removal, and LocationService's 60-s loop is
                // the fallback.
                runCatching { TamperAlertWorker.enqueue(context, TamperAlertWorker.TYPE_ADMIN_REMOVED, eventAtMs = disabledAtMs) }
                    .onFailure { Log.w(TAG, "could not enqueue tamper alert", it) }
            }
        }
    }

    companion object {
        /**
         * The device-admin component's fully qualified class name — the one code-side place that spells
         * it. The manifest and the hardware scripts still name the component; the JVM contract test
         * resolves their relative names against the manifest namespace and fails if either drifts
         * (issue #202).
         */
        val COMPONENT_CLASS: String = GuardianAdminReceiver::class.java.name

        @Volatile private var lastDisableGuardMs: Long = 0L

        private const val TAG = "FSDeviceAdmin"
    }
}
