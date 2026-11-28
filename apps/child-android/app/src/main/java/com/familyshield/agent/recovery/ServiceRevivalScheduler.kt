package com.familyshield.agent.recovery

import android.app.AlarmManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.os.SystemClock
import android.provider.Settings
import android.util.Log
import com.familyshield.agent.commands.CommandPollWorker

/**
 * Coordinates bounded service revival (osra-security#78):
 *
 * 1. **Exit-callback fast revival ([scheduleIfNeeded]):** bounded by
 *    [ServiceRevivalPolicy.MAX_REVIVALS_PER_WINDOW] (`3` per `10 minutes`) so MIUI memory/cleaner
 *    restarts cannot hot-loop; schedules an `ELAPSED_REALTIME_WAKEUP` alarm at `1.5 s` plus an
 *    expedited [CommandPollWorker.requestFetchNow].
 * 2. **Standing non-wakeup watchdog ([armStandingWatchdogIfNeeded]):** pre-armed while paired and
 *    active using `AlarmManager.ELAPSED_REALTIME` (non-wakeup, zero Doze/screen-off wakeups) at
 *    `60 s` (or `10 m` when backed off), surviving raw `SIGKILL` (`am_kill ... OneKeyClean`) where
 *    exit callbacks do not run.
 * 3. **Clean teardown ([cancelAll]):** cancels both alarms and clears persisted window state on
 *    unlink, unpair, or consent pause.
 */
object ServiceRevivalScheduler {

    private const val TAG = "ServiceRevival"
    private const val REQUEST_CODE_EXIT = 7801
    private const val REQUEST_CODE_STANDING = 7802

    fun scheduleIfNeeded(
        context: Context,
        paired: Boolean,
        consentPaused: Boolean,
        unlinkPending: Boolean = false,
        explicitlyStopping: Boolean = false,
    ): Boolean {
        val appContext = context.applicationContext
        val nowElapsed = SystemClock.elapsedRealtime()
        val boot = bootCount(appContext)
        val current = runCatching { ServiceRevivalState.read(appContext) }
            .getOrDefault(ServiceRevivalPolicy.WindowState())
        val decision = ServiceRevivalPolicy.evaluateExitRevival(
            paired = paired,
            consentPaused = consentPaused,
            unlinkPending = unlinkPending,
            explicitlyStopping = explicitlyStopping,
            nowElapsedMs = nowElapsed,
            current = current,
            bootCount = boot,
        )
        if (decision.nextState != current) {
            runCatching { ServiceRevivalState.write(appContext, decision.nextState) }
        }
        if (decision.capReachedNow) {
            Log.w(
                TAG,
                "fast service revival capped at ${ServiceRevivalPolicy.MAX_REVIVALS_PER_WINDOW} within 10m window; " +
                    "deferring to backed-off watchdog and periodic poll",
            )
        }
        if (!ServiceRevivalPolicy.shouldKeepStandingWatchdog(paired, consentPaused, unlinkPending)) {
            cancelAll(appContext)
            return false
        }
        if (!decision.schedule) {
            return false
        }
        runCatching {
            val alarm = appContext.getSystemService(AlarmManager::class.java)
            val intent = Intent(appContext, ServiceRevivalReceiver::class.java)
                .setAction(ServiceRevivalPolicy.ACTION_REVIVE_SERVICES)
            val pending = PendingIntent.getBroadcast(
                appContext,
                REQUEST_CODE_EXIT,
                intent,
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
            )
            alarm?.set(
                AlarmManager.ELAPSED_REALTIME_WAKEUP,
                nowElapsed + ServiceRevivalPolicy.REVIVAL_DELAY_MS,
                pending,
            )
        }.onFailure { Log.w(TAG, "could not schedule revival alarm", it) }

        runCatching {
            CommandPollWorker.requestFetchNow(appContext)
        }.onFailure { Log.w(TAG, "could not enqueue expedited poll revival", it) }
        return true
    }

    fun armStandingWatchdogIfNeeded(
        context: Context,
        paired: Boolean,
        consentPaused: Boolean,
        unlinkPending: Boolean = false,
    ): Boolean {
        val appContext = context.applicationContext
        if (!ServiceRevivalPolicy.shouldKeepStandingWatchdog(paired, consentPaused, unlinkPending)) {
            cancelAll(appContext)
            return false
        }
        val nowElapsed = SystemClock.elapsedRealtime()
        val boot = bootCount(appContext)
        val state = runCatching { ServiceRevivalState.read(appContext) }
            .getOrDefault(ServiceRevivalPolicy.WindowState())
        val delayMs = ServiceRevivalPolicy.standingWatchdogDelayMs(state, nowElapsed, boot)
        runCatching {
            val alarm = appContext.getSystemService(AlarmManager::class.java)
            val intent = Intent(appContext, ServiceRevivalReceiver::class.java)
                .setAction(ServiceRevivalPolicy.ACTION_STANDING_WATCHDOG)
            val pending = PendingIntent.getBroadcast(
                appContext,
                REQUEST_CODE_STANDING,
                intent,
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
            )
            // Non-wakeup ELAPSED_REALTIME: never wakes a sleeping/Doze phone; fires while interactive.
            alarm?.set(
                AlarmManager.ELAPSED_REALTIME,
                nowElapsed + delayMs,
                pending,
            )
        }.onFailure { Log.w(TAG, "could not arm standing revival watchdog", it) }
        return true
    }

    fun cancelAll(context: Context) {
        val appContext = context.applicationContext
        runCatching {
            val alarm = appContext.getSystemService(AlarmManager::class.java)
            cancelPending(appContext, alarm, REQUEST_CODE_EXIT, ServiceRevivalPolicy.ACTION_REVIVE_SERVICES)
            cancelPending(appContext, alarm, REQUEST_CODE_STANDING, ServiceRevivalPolicy.ACTION_STANDING_WATCHDOG)
        }.onFailure { Log.w(TAG, "could not cancel revival alarms", it) }
        runCatching { ServiceRevivalState.clear(appContext) }
    }

    private fun cancelPending(
        appContext: Context,
        alarm: AlarmManager?,
        requestCode: Int,
        action: String,
    ) {
        val intent = Intent(appContext, ServiceRevivalReceiver::class.java).setAction(action)
        val pending = PendingIntent.getBroadcast(
            appContext,
            requestCode,
            intent,
            PendingIntent.FLAG_NO_CREATE or PendingIntent.FLAG_IMMUTABLE,
        )
        if (pending != null) {
            alarm?.cancel(pending)
            pending.cancel()
        }
    }

    internal fun bootCount(context: Context): Int = runCatching {
        Settings.Global.getInt(context.contentResolver, Settings.Global.BOOT_COUNT, ServiceRevivalPolicy.NO_BOOT)
    }.getOrDefault(ServiceRevivalPolicy.NO_BOOT)
}
