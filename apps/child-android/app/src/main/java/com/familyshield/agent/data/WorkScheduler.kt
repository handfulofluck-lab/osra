package com.familyshield.agent.data

import android.content.Context
import androidx.work.Constraints
import androidx.work.ExistingPeriodicWorkPolicy
import androidx.work.ExistingWorkPolicy
import androidx.work.NetworkType
import androidx.work.OneTimeWorkRequestBuilder
import androidx.work.PeriodicWorkRequestBuilder
import androidx.work.WorkManager
import com.familyshield.agent.commands.CommandPollWorker
import com.familyshield.agent.telemetry.TelemetryWorker
import java.util.Calendar
import java.util.concurrent.TimeUnit

/** Enqueues the agent's periodic WorkManager jobs with ExistingPeriodicWorkPolicy.KEEP. */
object WorkScheduler {

    /** Enqueues (or keeps) the rules-sync (6 h), command-poll (60 s), telemetry (15 min) and
     * midnight-reset (24 h) jobs. */
    fun scheduleAll(context: Context) {
        val wm = WorkManager.getInstance(context)
        val network = Constraints.Builder().setRequiredNetworkType(NetworkType.CONNECTED).build()

        wm.enqueueUniquePeriodicWork(
            RulesSyncWorker.WORK_NAME,
            ExistingPeriodicWorkPolicy.KEEP,
            PeriodicWorkRequestBuilder<RulesSyncWorker>(6, TimeUnit.HOURS)
                .setConstraints(network)
                .build(),
        )
        // NOTE: §14.2 keeps FCM receivers but adds HTTP polling so testers without FCM get commands.
        // NOTE: WorkManager clamps any periodic interval below 15 min up to 15 min, so this "60 s"
        // poll effectively runs every ~15 min; the true 60 s cadence is covered by LocationService's
        // in-process command loop while the foreground service runs.
        wm.enqueueUniquePeriodicWork(
            CommandPollWorker.WORK_NAME,
            ExistingPeriodicWorkPolicy.KEEP,
            PeriodicWorkRequestBuilder<CommandPollWorker>(60, TimeUnit.SECONDS)
                .setConstraints(network)
                .build(),
        )
        wm.enqueueUniquePeriodicWork(
            TelemetryWorker.WORK_NAME,
            ExistingPeriodicWorkPolicy.KEEP,
            PeriodicWorkRequestBuilder<TelemetryWorker>(15, TimeUnit.MINUTES)
                .setConstraints(network)
                .build(),
        )
        wm.enqueueUniquePeriodicWork(
            MidnightResetWorker.WORK_NAME,
            ExistingPeriodicWorkPolicy.KEEP,
            PeriodicWorkRequestBuilder<MidnightResetWorker>(24, TimeUnit.HOURS)
                .setInitialDelay(msUntilNextMidnight(), TimeUnit.MILLISECONDS)
                .build(),
        )
    }

    /** Enqueues a one-off immediate rules refresh (run right after pairing, §14.2). */
    fun syncNow(context: Context) {
        val network = Constraints.Builder().setRequiredNetworkType(NetworkType.CONNECTED).build()
        WorkManager.getInstance(context).enqueueUniqueWork(
            RULES_SYNC_NOW,
            ExistingWorkPolicy.KEEP,
            OneTimeWorkRequestBuilder<RulesSyncWorker>()
                .setConstraints(network)
                .build(),
        )
    }

    /** Unique work name for the post-pairing one-off rules sync. */
    const val RULES_SYNC_NOW: String = "rules_sync_now"

    private fun msUntilNextMidnight(): Long {
        val now = Calendar.getInstance()
        val next = Calendar.getInstance().apply {
            add(Calendar.DAY_OF_YEAR, 1)
            set(Calendar.HOUR_OF_DAY, 0)
            set(Calendar.MINUTE, 0)
            set(Calendar.SECOND, 0)
            set(Calendar.MILLISECOND, 0)
        }
        return (next.timeInMillis - now.timeInMillis).coerceAtLeast(0L)
    }
}
