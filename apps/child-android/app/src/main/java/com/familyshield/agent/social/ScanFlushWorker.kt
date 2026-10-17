package com.familyshield.agent.social

import android.content.Context
import androidx.work.BackoffPolicy
import androidx.work.Constraints
import androidx.work.CoroutineWorker
import androidx.work.ExistingPeriodicWorkPolicy
import androidx.work.ExistingWorkPolicy
import androidx.work.NetworkType
import androidx.work.OneTimeWorkRequestBuilder
import androidx.work.PeriodicWorkRequestBuilder
import androidx.work.WorkManager
import androidx.work.WorkerParameters
import com.familyshield.agent.di.WorkerEntryPoint
import dagger.hilt.android.EntryPointAccessors
import java.util.concurrent.TimeUnit

/**
 * Plan 2.6: drains the durable scan queue under a network constraint — a one-shot with backoff after
 * a flush that left rows behind, and a 15-minute periodic sweep as the backstop (after a reboot, after
 * the process was killed with rows still queued).
 */
class ScanFlushWorker(context: Context, params: WorkerParameters) : CoroutineWorker(context, params) {

    override suspend fun doWork(): Result {
        val entry = EntryPointAccessors.fromApplication(applicationContext, WorkerEntryPoint::class.java)
        val queue = entry.socialScanQueue()
        runCatching { queue.flush() }
        return if (queue.pendingCount() > 0 && runAttemptCount < 5) Result.retry() else Result.success()
    }

    companion object {
        const val WORK_NAME: String = "scan_flush"
        private const val RETRY_NAME: String = "scan_flush_retry"

        private fun network() = Constraints.Builder().setRequiredNetworkType(NetworkType.CONNECTED).build()

        /** One retry pass once the network is back; a second request while one is queued is a no-op. */
        fun scheduleRetry(context: Context) {
            WorkManager.getInstance(context).enqueueUniqueWork(
                RETRY_NAME,
                ExistingWorkPolicy.KEEP,
                OneTimeWorkRequestBuilder<ScanFlushWorker>()
                    .setConstraints(network())
                    .setBackoffCriteria(BackoffPolicy.EXPONENTIAL, 30, TimeUnit.SECONDS)
                    .build(),
            )
        }

        /** The periodic backstop, registered with the other periodic work in WorkScheduler. */
        fun schedulePeriodic(context: Context) {
            WorkManager.getInstance(context).enqueueUniquePeriodicWork(
                WORK_NAME,
                ExistingPeriodicWorkPolicy.KEEP,
                PeriodicWorkRequestBuilder<ScanFlushWorker>(15, TimeUnit.MINUTES).setConstraints(network()).build(),
            )
        }
    }
}
