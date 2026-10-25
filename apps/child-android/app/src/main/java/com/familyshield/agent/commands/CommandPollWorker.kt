package com.familyshield.agent.commands

import android.app.NotificationChannel
import android.app.NotificationManager
import android.content.Context
import android.util.Log
import androidx.core.app.NotificationCompat
import androidx.work.Constraints
import androidx.work.CoroutineWorker
import androidx.work.ExistingWorkPolicy
import androidx.work.ForegroundInfo
import androidx.work.NetworkType
import androidx.work.OneTimeWorkRequestBuilder
import androidx.work.OutOfQuotaPolicy
import androidx.work.WorkManager
import androidx.work.WorkerParameters
import androidx.work.workDataOf
import com.familyshield.agent.di.WorkerEntryPoint
import com.familyshield.agent.services.IdleCadence
import com.familyshield.agent.services.LocationService
import dagger.hilt.android.EntryPointAccessors

/**
 * WorkManager wiring for the command poll (§14.2) and the fallback of a push wake-up (#319,
 * Decision 2). The fetch itself is [CommandPoller.pollOnce] — the same call the in-process wake-up
 * makes — so this worker only decides *when* it runs (the 60-second periodic job, or a one-shot
 * expedited [requestFetchNow]) and *what a failure means* (up to three retries).
 *
 * Roadmap 5.8 (#353): the periodic run is skipped while [LocationService] is running, since that
 * service polls on the server's cadence ([IdleCadence.workerShouldPoll]); a run [requestFetchNow]
 * enqueued carries [KEY_WAKE] and always fetches.
 */
class CommandPollWorker(
    context: Context,
    params: WorkerParameters,
) : CoroutineWorker(context, params) {

    /** Runs one poll pass; a failed fetch is retried up to three attempts, then fails the work. */
    override suspend fun doWork(): Result {
        val wake = inputData.getBoolean(KEY_WAKE, false)
        if (!IdleCadence.workerShouldPoll(LocationService.isServiceRunning, wake)) return Result.success()
        val entryPoint = EntryPointAccessors.fromApplication(applicationContext, WorkerEntryPoint::class.java)
        return try {
            entryPoint.commandPoller().pollOnce()
            Result.success()
        } catch (e: Exception) {
            Log.w(TAG, "command poll failed", e)
            if (runAttemptCount < 3) Result.retry() else Result.failure()
        }
    }

    /**
     * Expedited work runs as a foreground service below Android 12, and WorkManager refuses a worker
     * that cannot describe its notification. Only [requestFetchNow] takes this path; the 60-second
     * periodic poll is never expedited. The channel is created here because the worker has no
     * `onCreate` and the wake may be the process's first work.
     */
    override suspend fun getForegroundInfo(): ForegroundInfo {
        val context = applicationContext
        context.getSystemService(NotificationManager::class.java)
            ?.createNotificationChannel(
                NotificationChannel(WAKE_CHANNEL, "Command checks", NotificationManager.IMPORTANCE_LOW),
            )
        val notification = NotificationCompat.Builder(context, WAKE_CHANNEL)
            .setSmallIcon(android.R.drawable.ic_dialog_info)
            .setContentTitle("OSRA")
            .setContentText("Checking for parent commands")
            .setPriority(NotificationCompat.PRIORITY_LOW)
            .setOngoing(true)
            .build()
        return ForegroundInfo(WAKE_NOTIFICATION_ID, notification)
    }

    companion object {
        /** Unique work name for the periodic command poll. */
        const val WORK_NAME: String = "command_poll"

        /**
         * Unique work name for the one-shot fetch a push wake-up enqueues. Distinct from [WORK_NAME]
         * because WorkManager's unique-name space is shared: enqueuing one-shot work under
         * `command_poll` would collide with (and replace) the periodic poll itself.
         */
        const val WAKE_WORK_NAME: String = "command_poll_wake"

        /** Input-data flag set by [requestFetchNow]: a push woke this run, so it fetches even while [LocationService] runs. */
        const val KEY_WAKE: String = "wake"

        private const val TAG: String = "CommandPollWorker"
        private const val WAKE_CHANNEL: String = "command_poll_wake"
        private const val WAKE_NOTIFICATION_ID: Int = 44

        /**
         * The wake-up fallback: runs the poll in a worker when the in-process attempt could not run
         * (#319, Decision 2).
         *
         * Expedited, so a high-priority push is not queued behind Doze, with WorkManager's
         * `RUN_AS_NON_EXPEDITED` fallback when the expedited quota is spent. `KEEP` rather than
         * `REPLACE`: a burst of pushes collapses into the one pending/running fetch (it drains the
         * whole queue anyway), and the fallback must not cancel a fetch that is already under way.
         * Network-constrained like the periodic poll, because a fetch without network can only fail.
         */
        fun requestFetchNow(context: Context) {
            val network = Constraints.Builder().setRequiredNetworkType(NetworkType.CONNECTED).build()
            WorkManager.getInstance(context).enqueueUniqueWork(
                WAKE_WORK_NAME,
                ExistingWorkPolicy.KEEP,
                OneTimeWorkRequestBuilder<CommandPollWorker>()
                    .setConstraints(network)
                    .setInputData(workDataOf(KEY_WAKE to true))
                    .setExpedited(OutOfQuotaPolicy.RUN_AS_NON_EXPEDITED_WORK_REQUEST)
                    .build(),
            )
        }
    }
}
