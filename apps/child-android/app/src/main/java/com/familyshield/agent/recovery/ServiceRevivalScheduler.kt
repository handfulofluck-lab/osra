package com.familyshield.agent.recovery

import android.app.AlarmManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.os.SystemClock
import android.util.Log
import com.familyshield.agent.commands.CommandPollWorker

/**
 * Schedules immediate service revival when an active foreground service is removed from Recents or
 * torn down unexpectedly (osra-security#78).
 *
 * Uses two independent paths so OEM restriction on either one does not stall recovery for 15 minutes:
 * 1. An internal `ELAPSED_REALTIME_WAKEUP` alarm (`set(...)`, which requires no runtime exact-alarm
 *    special access) targeting [ServiceRevivalReceiver] at [ServiceRevivalPolicy.REVIVAL_DELAY_MS].
 * 2. An expedited one-shot [CommandPollWorker.requestFetchNow] work request, whose `doWork()` also
 *    runs [ServiceRecovery.run].
 */
object ServiceRevivalScheduler {

    private const val TAG = "ServiceRevival"
    private const val REQUEST_CODE = 7801

    fun scheduleIfNeeded(
        context: Context,
        paired: Boolean,
        consentPaused: Boolean,
        unlinkPending: Boolean = false,
        explicitlyStopping: Boolean = false,
    ): Boolean {
        if (!ServiceRevivalPolicy.shouldScheduleOnServiceExit(
                paired = paired,
                consentPaused = consentPaused,
                unlinkPending = unlinkPending,
                explicitlyStopping = explicitlyStopping,
            )
        ) {
            return false
        }
        val appContext = context.applicationContext
        runCatching {
            val alarm = appContext.getSystemService(AlarmManager::class.java)
            val intent = Intent(appContext, ServiceRevivalReceiver::class.java)
                .setAction(ServiceRevivalPolicy.ACTION_REVIVE_SERVICES)
            val pending = PendingIntent.getBroadcast(
                appContext,
                REQUEST_CODE,
                intent,
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
            )
            alarm?.set(
                AlarmManager.ELAPSED_REALTIME_WAKEUP,
                SystemClock.elapsedRealtime() + ServiceRevivalPolicy.REVIVAL_DELAY_MS,
                pending,
            )
        }.onFailure { Log.w(TAG, "could not schedule revival alarm", it) }

        runCatching {
            CommandPollWorker.requestFetchNow(appContext)
        }.onFailure { Log.w(TAG, "could not enqueue expedited poll revival", it) }
        return true
    }
}
