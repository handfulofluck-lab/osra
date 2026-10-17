package com.familyshield.agent.security

import android.content.Context
import android.util.Log
import androidx.work.CoroutineWorker
import androidx.work.ExistingWorkPolicy
import androidx.work.OneTimeWorkRequestBuilder
import androidx.work.OutOfQuotaPolicy
import androidx.work.WorkManager
import androidx.work.WorkerParameters
import androidx.work.workDataOf
import com.familyshield.agent.di.WorkerEntryPoint
import com.familyshield.agent.network.dto.AlertDto
import dagger.hilt.android.EntryPointAccessors

/**
 * Posts one `tamper` alert to the parent (ADR-0010 §4). Enqueued as expedited work by
 * [FamilyShieldDeviceAdmin.onDisabled] (admin removed) and by the accessibility guard (a protection
 * screen was opened without the PIN), so the parent hears within seconds while the device is online
 * and WorkManager retries when it is not. Idempotent per type: the 60-s loop in LocationService also
 * drains the admin-disabled flag, and the server throttles duplicates per device.
 */
class TamperAlertWorker(context: Context, params: WorkerParameters) : CoroutineWorker(context, params) {

    override suspend fun doWork(): Result {
        val type = inputData.getString(KEY_TYPE) ?: return Result.success()
        val detail = inputData.getString(KEY_DETAIL) ?: ""
        val entry = EntryPointAccessors.fromApplication(applicationContext, WorkerEntryPoint::class.java)
        val settings = entry.agentSettings()
        val childId = settings.childId() ?: return Result.success() // not paired: nobody to tell
        return try {
            entry.apiService().postInternalAlert(
                AlertDto(
                    childId = childId,
                    deviceId = settings.deviceId(),
                    severity = "critical",
                    category = "tamper",
                    title = TITLES[type] ?: "Protection was changed",
                    body = detail.ifBlank { BODIES[type] ?: "" },
                    metadata = mapOf("type" to type),
                ),
            )
            if (type == TYPE_ADMIN_REMOVED) TamperState.setAdminDisabledPending(applicationContext, false)
            Result.success()
        } catch (e: Exception) {
            Log.w(TAG, "tamper alert '$type' failed; retrying", e)
            if (runAttemptCount < 5) Result.retry() else Result.failure()
        }
    }

    companion object {
        const val TYPE_ADMIN_REMOVED = "device_admin_removed"
        const val TYPE_GUARD_TRIGGERED = "protection_screen_opened"
        private const val KEY_TYPE = "type"
        private const val KEY_DETAIL = "detail"
        private const val TAG = "TamperAlertWorker"

        private val TITLES = mapOf(
            TYPE_ADMIN_REMOVED to "Device admin was removed",
            TYPE_GUARD_TRIGGERED to "Someone tried to remove protection",
        )
        private val BODIES = mapOf(
            TYPE_ADMIN_REMOVED to "OSRA's device-admin rights were turned off on this device. Uninstall is no longer blocked.",
            TYPE_GUARD_TRIGGERED to "A protection-removal screen was opened on this device and the PIN was asked for.",
        )

        /** Enqueues one expedited alert of [type]; a second enqueue of the same type replaces the first. */
        fun enqueue(context: Context, type: String, detail: String = "") {
            val request = OneTimeWorkRequestBuilder<TamperAlertWorker>()
                .setExpedited(OutOfQuotaPolicy.RUN_AS_NON_EXPEDITED_WORK_REQUEST)
                .setInputData(workDataOf(KEY_TYPE to type, KEY_DETAIL to detail))
                .build()
            WorkManager.getInstance(context).enqueueUniqueWork("tamper_alert_$type", ExistingWorkPolicy.REPLACE, request)
        }
    }
}
