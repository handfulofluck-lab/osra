package com.familyshield.agent.telemetry

import android.content.Context
import androidx.work.CoroutineWorker
import androidx.work.WorkerParameters
import com.familyshield.agent.di.WorkerEntryPoint
import dagger.hilt.android.EntryPointAccessors

/** Every-15-min job: aggregates usage events and uploads the telemetry delta. */
class TelemetryWorker(
    context: Context,
    params: WorkerParameters,
) : CoroutineWorker(context, params) {

    /** Aggregates + uploads; retries on network failure. */
    override suspend fun doWork(): Result {
        return try {
            val entryPoint = EntryPointAccessors.fromApplication(applicationContext, WorkerEntryPoint::class.java)
            entryPoint.usageReporter().aggregateAndUpload()
            // Roadmap 3.4: piggyback on the same tick; the reporter uploads only when the list changed.
            entryPoint.installedAppsReporter().reportIfChanged()
            entryPoint.commsCapture().flush() // Feature #6 backstop alongside the 5-min in-process loop
            Result.success()
        } catch (e: Exception) {
            if (runAttemptCount < 3) Result.retry() else Result.failure()
        }
    }

    companion object {
        /** Unique work name for the periodic telemetry aggregation. */
        const val WORK_NAME: String = "telemetry_upload"
    }
}
