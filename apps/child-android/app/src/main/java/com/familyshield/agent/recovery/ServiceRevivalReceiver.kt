package com.familyshield.agent.recovery

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.os.SystemClock
import android.util.Log
import com.familyshield.agent.di.WorkerEntryPoint
import dagger.hilt.android.EntryPointAccessors

/**
 * Internal (`android:exported="false"`) broadcast receiver woken by [ServiceRevivalScheduler] on:
 * - [ServiceRevivalPolicy.ACTION_REVIVE_SERVICES] (fast post-exit revival), or
 * - [ServiceRevivalPolicy.ACTION_STANDING_WATCHDOG] (pre-armed standing non-wakeup `ELAPSED_REALTIME`
 *   check that recovers after a raw kernel `SIGKILL` where exit callbacks never ran).
 */
class ServiceRevivalReceiver : BroadcastReceiver() {

    override fun onReceive(context: Context, intent: Intent?) {
        val appContext = context.applicationContext
        val action = intent?.action
        val plan = handleBroadcast(action) {
            ServiceRecovery.run(appContext)
        } ?: return

        runCatching {
            val entry = EntryPointAccessors.fromApplication(appContext, WorkerEntryPoint::class.java)
            val settings = entry.agentSettings()
            val paired = settings.isPairedSync()
            val consentPaused = entry.consentState().isPaused()
            val unlinkPending = settings.unlinkPendingSync()
            if (action == ServiceRevivalPolicy.ACTION_STANDING_WATCHDOG) {
                val nowElapsed = SystemClock.elapsedRealtime()
                val boot = ServiceRevivalScheduler.bootCount(appContext)
                val current = ServiceRevivalState.read(appContext)
                val updated = ServiceRevivalPolicy.recordStandingRecovery(
                    current = current,
                    planEmpty = plan.isEmpty,
                    nowElapsedMs = nowElapsed,
                    bootCount = boot,
                )
                if (updated != current) {
                    ServiceRevivalState.write(appContext, updated)
                }
            }
            ServiceRevivalScheduler.armStandingWatchdogIfNeeded(
                context = appContext,
                paired = paired,
                consentPaused = consentPaused,
                unlinkPending = unlinkPending,
            )
        }.onFailure { Log.w(TAG, "could not update standing revival watchdog", it) }
    }

    companion object {
        private const val TAG = "ServiceRevivalReceiver"

        internal fun handleBroadcast(
            action: String?,
            runRecovery: () -> ServiceRecoveryPolicy.Plan,
        ): ServiceRecoveryPolicy.Plan? {
            if (action != ServiceRevivalPolicy.ACTION_REVIVE_SERVICES &&
                action != ServiceRevivalPolicy.ACTION_STANDING_WATCHDOG
            ) {
                return null
            }
            return runCatching { runRecovery() }
                .onFailure { Log.w(TAG, "service revival failed", it) }
                .getOrNull()
        }
    }
}
