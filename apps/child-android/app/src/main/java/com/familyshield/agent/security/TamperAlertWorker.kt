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
 * [GuardianAdminReceiver.onDisabled] (admin removed) and by the accessibility guard (a protection
 * screen was opened without the PIN), so the parent hears within seconds while the device is online
 * and WorkManager retries when it is not.
 *
 * Issue #225: the admin-removed alert carries a dedupe key — device + type + the timestamp
 * `onDisabled` recorded — because two paths enqueue this worker for one deactivation (the receiver,
 * and the 60-s drain in LocationService when it sees the pending flag or the tier drop). The second
 * run skips the POST; the server's unique index covers the case where both are already in flight.
 * `admin_disabled_pending` is cleared only after a post succeeds (or after this worker confirms one
 * already did), never on failure, so an offline device retries.
 */
class TamperAlertWorker(context: Context, params: WorkerParameters) : CoroutineWorker(context, params) {

    override suspend fun doWork(): Result {
        val type = inputData.getString(KEY_TYPE) ?: return Result.success()
        val detail = inputData.getString(KEY_DETAIL) ?: ""
        val entry = EntryPointAccessors.fromApplication(applicationContext, WorkerEntryPoint::class.java)
        val settings = entry.agentSettings()
        val childId = settings.childId() ?: return Result.success() // not paired: nobody to tell
        val dedupeKey = if (type == TYPE_ADMIN_REMOVED) {
            TamperAlertDedupe.adminRemovalKey(settings.deviceId(), eventTimestamp())
        } else {
            null
        }
        val dispatcher = TamperAlertDispatcher(
            wasPosted = { TamperState.isTamperAlertPosted(applicationContext, it) },
            recordPosted = { TamperState.markTamperAlertPosted(applicationContext, it) },
        )
        return try {
            dispatcher.dispatch(dedupeKey) {
                entry.apiService().postInternalAlert(
                    AlertDto(
                        childId = childId,
                        deviceId = settings.deviceId(),
                        severity = "critical",
                        category = "tamper",
                        title = TITLES[type] ?: "Protection was changed",
                        body = detail.ifBlank { BODIES[type] ?: "" },
                        metadata = mapOf("type" to type),
                        dedupeKey = dedupeKey,
                    ),
                )
            }
            if (type == TYPE_ADMIN_REMOVED) TamperState.setAdminDisabledPending(applicationContext, false)
            Result.success()
        } catch (e: Exception) {
            Log.w(TAG, "tamper alert '$type' failed; retrying", e)
            if (runAttemptCount < 5) Result.retry() else Result.failure()
        }
    }

    /**
     * The disable timestamp the receiver recorded. The work-input copy is the authority so a
     * re-enable (`onEnabled`) cannot redirect a late retry to a different key; the persisted value
     * is the fallback, and a tier drop observed without `onDisabled` stamps itself now.
     */
    private fun eventTimestamp(): Long {
        val fromInput = inputData.getLong(KEY_EVENT_AT_MS, 0L)
        if (fromInput > 0L) return fromInput
        val stored = TamperState.adminDisabledAtMs(applicationContext)
        if (stored > 0L) return stored
        val now = System.currentTimeMillis()
        TamperState.setAdminDisabledAt(applicationContext, now)
        return now
    }

    companion object {
        const val TYPE_ADMIN_REMOVED = "device_admin_removed"
        const val TYPE_GUARD_TRIGGERED = "protection_screen_opened"
        const val TYPE_VPN_REVOKED = "content_filter_disconnected"
        private const val KEY_TYPE = "type"
        private const val KEY_DETAIL = "detail"
        private const val KEY_EVENT_AT_MS = "event_at_ms"
        private const val TAG = "TamperAlertWorker"

        private val TITLES = mapOf(
            TYPE_ADMIN_REMOVED to "Device admin was removed",
            TYPE_GUARD_TRIGGERED to "Someone tried to remove protection",
            TYPE_VPN_REVOKED to "Content filter was disconnected",
        )
        private val BODIES = mapOf(
            TYPE_ADMIN_REMOVED to "OSRA's device-admin rights were turned off on this device. Uninstall is no longer blocked.",
            TYPE_GUARD_TRIGGERED to "A protection-removal screen was opened on this device and the PIN was asked for.",
            TYPE_VPN_REVOKED to "OSRA's web filter (VPN) was disconnected on this device — another VPN app took over or it was turned off in Settings. Web filtering is off until it is reconnected.",
        )

        /** Enqueues one expedited alert of [type]; a second enqueue of the same type replaces the first. */
        fun enqueue(context: Context, type: String, detail: String = "", eventAtMs: Long = 0L) {
            val request = OneTimeWorkRequestBuilder<TamperAlertWorker>()
                .setExpedited(OutOfQuotaPolicy.RUN_AS_NON_EXPEDITED_WORK_REQUEST)
                .setInputData(
                    workDataOf(
                        KEY_TYPE to type,
                        KEY_DETAIL to detail,
                        KEY_EVENT_AT_MS to eventAtMs,
                    ),
                )
                .build()
            WorkManager.getInstance(context).enqueueUniqueWork("tamper_alert_$type", ExistingWorkPolicy.REPLACE, request)
        }
    }
}
