package com.familyshield.agent.security

import android.app.AppOpsManager
import android.app.usage.UsageEvents
import android.app.usage.UsageStatsManager
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import android.os.PowerManager
import android.os.Process
import android.provider.Settings
import android.util.Log
import com.familyshield.agent.di.WorkerEntryPoint
import com.familyshield.agent.services.AccessibilityMonitorService
import com.familyshield.agent.services.LocationService
import com.familyshield.agent.setup.SetupCompletionStore
import com.familyshield.agent.vpn.FilterVpnService
import dagger.hilt.android.EntryPointAccessors
import java.util.concurrent.atomic.AtomicBoolean
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.delay
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch

/**
 * Degraded-state fallback tamper watcher (osra-security#78).
 *
 * Hosted inside the agent's foreground services ([LocationService] and [FilterVpnService]). While
 * [AccessibilityMonitorService.isRunning] is `true`, this watcher sleeps on [UnboundTamperPolicy.DORMANT_CHECK_MS]
 * and performs zero `UsageStatsManager` queries. When Accessibility is unbound on a paired,
 * setup-completed device, it polls recent `ACTIVITY_RESUMED` transitions for phone-wide
 * second-space setup screens while shared multi-app host screens defer to OSRA's own-component
 * callbacks ([GuardianAdminReceiver.onDisableRequested] and `android:manageSpaceActivity`).
 */
object UnboundTamperWatch {

    private const val TAG = "UnboundTamperWatch"

    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)
    private val running = AtomicBoolean(false)
    @Volatile private var watchJob: Job? = null
    @Volatile private var lastGuardMs: Long = 0L

    fun ensureStarted(context: Context) {
        val appContext = context.applicationContext
        if (!running.compareAndSet(false, true)) return
        watchJob = scope.launch {
            try {
                loop(appContext)
            } catch (e: CancellationException) {
                throw e
            } catch (e: Exception) {
                Log.w(TAG, "unbound tamper watch stopped unexpectedly", e)
            } finally {
                running.set(false)
            }
        }
    }

    fun stopIfNoHostRunning() {
        if (LocationService.isServiceRunning || FilterVpnService.isRunning) return
        watchJob?.cancel()
        watchJob = null
        running.set(false)
    }

    private suspend fun loop(appContext: Context) {
        var top: UnboundTamperPolicy.TopActivity? = null
        var lastQueryMs = 0L
        while (scope.isActive && (LocationService.isServiceRunning || FilterVpnService.isRunning)) {
            if (AccessibilityMonitorService.isRunning) {
                top = null
                lastQueryMs = 0L
                delay(UnboundTamperPolicy.DORMANT_CHECK_MS)
                continue
            }
            val interactive = appContext.getSystemService(PowerManager::class.java)?.isInteractive ?: true
            if (!interactive) {
                delay(UnboundTamperPolicy.DORMANT_CHECK_MS)
                continue
            }
            val entry = runCatching {
                EntryPointAccessors.fromApplication(appContext, WorkerEntryPoint::class.java)
            }.getOrNull()
            if (entry == null) {
                delay(UnboundTamperPolicy.DORMANT_CHECK_MS)
                continue
            }
            val settings = entry.agentSettings()
            val paired = settings.isPairedSync()
            val unlinkPending = settings.unlinkPendingSync()
            val deviceId = settings.deviceIdSync()
            val setupCompleted = SetupCompletionStore.isCompletedForDevice(appContext, deviceId)
            val pinConfigured = entry.parentPinStore().isConfigured()
            val consentPaused = entry.consentState().isPaused()
            val canOverlay = Settings.canDrawOverlays(appContext)
            val hasUsage = hasUsageAccess(appContext)

            val monitor = UnboundTamperPolicy.shouldMonitor(
                paired = paired,
                unlinkPending = unlinkPending,
                setupCompletedOnce = setupCompleted,
                pinConfigured = pinConfigured,
                consentPaused = consentPaused,
                accessibilityBound = AccessibilityMonitorService.isRunning,
                canDrawOverlays = canOverlay,
                usageAccessGranted = hasUsage,
                interactive = interactive,
            )
            if (!monitor) {
                top = null
                lastQueryMs = 0L
                delay(UnboundTamperPolicy.DORMANT_CHECK_MS)
                continue
            }

            val nowMs = System.currentTimeMillis()
            val fromMs = if (lastQueryMs <= 0L) {
                nowMs - UnboundTamperPolicy.INITIAL_LOOKBACK_MS
            } else {
                (lastQueryMs - UnboundTamperPolicy.QUERY_OVERLAP_MS).coerceAtLeast(0L)
            }
            top = queryLatestTop(appContext, top, fromMs, nowMs)
            lastQueryMs = nowMs

            val screen = UnboundTamperPolicy.classifyUnboundTop(
                top = top,
                ownPackage = appContext.packageName,
            )
            val suppressed = GuardDebouncePolicy.suppress(
                nowMs = nowMs,
                lastGuardMs = lastGuardMs,
                gateShowing = GuardGateState.showing,
                gateResumedSinceLaunch = GuardGateState.resumedSince(lastGuardMs),
                gateMultiWindow = GuardGateState.multiWindow,
            )
            if (UnboundTamperPolicy.shouldLaunchPinGate(
                    screen = screen,
                    pinConfigured = pinConfigured,
                    nowMs = nowMs,
                    graceUntilMs = TamperState.graceUntil(appContext),
                    sanctionedUntilMs = TamperState.sanctionedRemovalUntil(appContext),
                    gateSuppressed = suppressed,
                )
            ) {
                lastGuardMs = nowMs
                stepInFromUnboundWatch(appContext, screen, top?.packageName, nowMs)
            }
            delay(UnboundTamperPolicy.POLL_INTERVAL_MS)
        }
    }

    private fun queryLatestTop(
        context: Context,
        previous: UnboundTamperPolicy.TopActivity?,
        fromMs: Long,
        toMs: Long,
    ): UnboundTamperPolicy.TopActivity? {
        val usm = context.getSystemService(UsageStatsManager::class.java) ?: return previous
        val rawEvents = runCatching { usm.queryEvents(fromMs, toMs) }.getOrNull() ?: return previous
        val batch = ArrayList<UnboundTamperPolicy.ResumedEvent>(16)
        val cursor = UsageEvents.Event()
        while (rawEvents.hasNextEvent()) {
            rawEvents.getNextEvent(cursor)
            if (cursor.eventType == UnboundTamperPolicy.EVENT_ACTIVITY_RESUMED) {
                batch.add(
                    UnboundTamperPolicy.ResumedEvent(
                        packageName = cursor.packageName,
                        className = cursor.className,
                        timestampMs = cursor.timeStamp,
                        eventType = cursor.eventType,
                    ),
                )
            }
        }
        return UnboundTamperPolicy.latestResumedActivity(previous, batch)
    }

    private fun stepInFromUnboundWatch(
        context: Context,
        screen: TamperScreen,
        pkg: String?,
        nowMs: Long,
    ) {
        runCatching {
            context.startActivity(
                Intent(context, TamperGuardTaskActivity::class.java)
                    .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP)
                    .putExtra(TamperGuardActivity.EXTRA_REASON, TamperGuardActivity.REASON_SETTINGS),
            )
        }.onFailure { Log.w(TAG, "failed to launch TamperGuardTaskActivity from unbound watch", it) }

        val attempt = GuardAttemptWindow.record(TamperState.guardAttemptWindow(context), nowMs, screen.name.lowercase())
        TamperState.setGuardAttemptWindow(context, attempt.state)
        runCatching {
            TamperAlertWorker.enqueue(
                context,
                TamperAlertWorker.TYPE_GUARD_TRIGGERED,
                detail = "Screen: ${screen.name.lowercase()} in $pkg",
                windowStartMs = attempt.state.windowStartMs,
                attemptCount = attempt.state.count,
                screens = attempt.state.screens,
            )
        }.onFailure { Log.w(TAG, "failed to enqueue guard-triggered alert from unbound watch", it) }
    }

    private fun hasUsageAccess(context: Context): Boolean {
        val ops = context.getSystemService(AppOpsManager::class.java) ?: return false
        val mode = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            ops.unsafeCheckOpNoThrow(AppOpsManager.OPSTR_GET_USAGE_STATS, Process.myUid(), context.packageName)
        } else {
            @Suppress("DEPRECATION")
            ops.checkOpNoThrow(AppOpsManager.OPSTR_GET_USAGE_STATS, Process.myUid(), context.packageName)
        }
        return mode == AppOpsManager.MODE_ALLOWED ||
            (mode == AppOpsManager.MODE_DEFAULT &&
                context.checkCallingOrSelfPermission(android.Manifest.permission.PACKAGE_USAGE_STATS) == PackageManager.PERMISSION_GRANTED)
    }
}
