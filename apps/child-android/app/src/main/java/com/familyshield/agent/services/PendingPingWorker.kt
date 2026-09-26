package com.familyshield.agent.services

import android.content.Context
import androidx.work.Constraints
import androidx.work.CoroutineWorker
import androidx.work.ExistingPeriodicWorkPolicy
import androidx.work.NetworkType
import androidx.work.PeriodicWorkRequestBuilder
import androidx.work.WorkManager
import androidx.work.WorkerParameters
import com.familyshield.agent.di.WorkerEntryPoint
import com.familyshield.agent.network.dto.LocationPingBatchDto
import com.familyshield.agent.network.dto.LocationPingDto
import dagger.hilt.android.EntryPointAccessors
import java.time.Instant
import java.util.concurrent.TimeUnit
import kotlinx.coroutines.sync.withLock

/** Flushes Room-persisted location pings to the backend whenever the network is available. */
class PendingPingWorker(
    context: Context,
    params: WorkerParameters,
) : CoroutineWorker(context, params) {

    /** Uploads all pending pings; retries on failure so nothing is dropped. */
    override suspend fun doWork(): Result {
        val deps = EntryPointAccessors.fromApplication(applicationContext, WorkerEntryPoint::class.java)
        val dao = deps.database().pendingPingDao()
        // NOTE: shares LocationService.FLUSH_MUTEX so a concurrent service flush cannot upload
        // the same rows twice or clear rows this worker has not sent.
        return LocationService.FLUSH_MUTEX.withLock {
            val pending = dao.all()
            if (pending.isEmpty()) return Result.success()
            try {
                deps.apiService().postLocationPings(
                    LocationPingBatchDto(
                        pending.map {
                            LocationPingDto(
                                lat = it.lat,
                                lng = it.lng,
                                accuracyM = it.accuracyM,
                                timestamp = Instant.ofEpochMilli(it.timestamp).toString(),
                            )
                        },
                    ),
                )
                dao.clear()
                Result.success()
            } catch (e: Exception) {
                if (runAttemptCount < 3) Result.retry() else Result.failure()
            }
        }
    }

    companion object {
        /** Unique work name for the periodic pending-ping flush. */
        const val WORK_NAME: String = "pending_ping_flush"

        /** Enqueues (or keeps) a 30-min network-constrained flush job. */
        fun schedule(context: Context) {
            WorkManager.getInstance(context).enqueueUniquePeriodicWork(
                WORK_NAME,
                ExistingPeriodicWorkPolicy.KEEP,
                PeriodicWorkRequestBuilder<PendingPingWorker>(30, TimeUnit.MINUTES)
                    .setConstraints(
                        Constraints.Builder().setRequiredNetworkType(NetworkType.CONNECTED).build(),
                    )
                    .build(),
            )
        }
    }
}
