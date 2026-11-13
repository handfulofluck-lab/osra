package com.familyshield.agent.update

import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.content.IntentSender
import android.os.Build
import android.util.Log
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
import dagger.hilt.android.qualifiers.ApplicationContext
import java.util.concurrent.TimeUnit
import javax.inject.Inject
import javax.inject.Singleton
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext

/**
 * ADR-0039 D5.1's Full-only check: every 12 h, once at boot and once after pairing. The work itself is
 * [FullUpdater]; this class only schedules it and never lets an exception out of `doWork`.
 */
class FullUpdateWorker(
    context: Context,
    params: WorkerParameters,
) : CoroutineWorker(context, params) {

    override suspend fun doWork(): Result {
        val outcome: FullUpdateOutcome = try {
            withContext(Dispatchers.IO) {
                FullUpdater(
                    context = applicationContext,
                    keys = FullUpdateKeys.byKeyId,
                    state = FullUpdateStateStore(applicationContext),
                ).check(installStatusSender())
            }
        } catch (e: Exception) {
            Log.e(TAG, "update_refused:worker_failed", e)
            return Result.failure()
        }
        if (outcome is FullUpdateOutcome.InstallRequested) {
            Log.i(TAG, "update_install_requested:${outcome.versionCode}")
        }
        return if (outcome.isTransient() && runAttemptCount < MAX_ATTEMPTS) Result.retry() else Result.success()
    }

    private fun installStatusSender(): IntentSender {
        val flags: Int = PendingIntent.FLAG_UPDATE_CURRENT or
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) PendingIntent.FLAG_MUTABLE else 0
        return PendingIntent.getBroadcast(
            applicationContext,
            INSTALL_STATUS_REQUEST,
            Intent(applicationContext, FullUpdateInstallReceiver::class.java),
            flags,
        ).intentSender
    }

    private fun FullUpdateOutcome.isTransient(): Boolean = this is FullUpdateOutcome.Refused &&
        reason in TRANSIENT_REASONS

    companion object {
        const val WORK_NAME: String = "full_update_check"
        const val CHECK_NOW: String = "full_update_check_now"

        private const val TAG = "FullUpdateWorker"
        private const val INSTALL_STATUS_REQUEST = 3901
        private const val MAX_ATTEMPTS = 3
        private val TRANSIENT_REASONS: Set<String> = setOf(
            FullUpdater.REASON_NETWORK_ERROR,
            FullUpdater.REASON_FETCH_FAILED,
            FullUpdater.REASON_DOWNLOAD_FAILED,
            FullUpdater.REASON_INSTALL_FAILED,
            FullUpdater.REASON_CHECK_FAILED,
        )

        fun schedulePeriodic(context: Context) {
            WorkManager.getInstance(context).enqueueUniquePeriodicWork(
                WORK_NAME,
                ExistingPeriodicWorkPolicy.KEEP,
                PeriodicWorkRequestBuilder<FullUpdateWorker>(12, TimeUnit.HOURS)
                    .setConstraints(networkConstraints())
                    .setBackoffCriteria(BackoffPolicy.EXPONENTIAL, 30, TimeUnit.MINUTES)
                    .build(),
            )
        }

        fun checkNow(context: Context) {
            WorkManager.getInstance(context).enqueueUniqueWork(
                CHECK_NOW,
                ExistingWorkPolicy.KEEP,
                OneTimeWorkRequestBuilder<FullUpdateWorker>()
                    .setConstraints(networkConstraints())
                    .setBackoffCriteria(BackoffPolicy.EXPONENTIAL, 30, TimeUnit.MINUTES)
                    .build(),
            )
        }

        private fun networkConstraints(): Constraints =
            Constraints.Builder().setRequiredNetworkType(NetworkType.CONNECTED).build()
    }
}

/** ADR-0039 D5.1: what the `full` flavour binds to [UpdateCheckScheduler]. */
@Singleton
class FullUpdateCheckScheduler @Inject constructor(
    @ApplicationContext private val context: Context,
) : UpdateCheckScheduler {
    override fun schedulePeriodic() = FullUpdateWorker.schedulePeriodic(context)

    override fun checkNow() = FullUpdateWorker.checkNow(context)
}
