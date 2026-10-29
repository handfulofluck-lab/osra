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
 *
 * Issue #227: a protection-screen alert is an aggregate. [GuardAttemptWindow] gives the worker the
 * window start and the running count; the server key names the window, and `attemptCount` makes a
 * repeat update that row instead of inserting (and paging) again. The client-side key includes the
 * count so a higher count is posted while a retry of the same work is a no-op.
 */
class TamperAlertWorker(context: Context, params: WorkerParameters) : CoroutineWorker(context, params) {

    override suspend fun doWork(): Result {
        val type = inputData.getString(KEY_TYPE) ?: return Result.success()
        val detail = inputData.getString(KEY_DETAIL) ?: ""
        val app = inputData.getString(KEY_APP).orEmpty()
        val layout = inputData.getString(KEY_LAYOUT).orEmpty()
        val entry = EntryPointAccessors.fromApplication(applicationContext, WorkerEntryPoint::class.java)
        val settings = entry.agentSettings()
        val childId = settings.childId() ?: return Result.success() // not paired: nobody to tell
        val deviceId = settings.deviceId()
        val guardWindow = guardWindow()
        val dedupeKey = when (type) {
            TYPE_ADMIN_REMOVED -> TamperAlertDedupe.adminRemovalKey(deviceId, eventTimestamp())
            TYPE_GUARD_TRIGGERED -> guardWindow?.let {
                TamperAlertDedupe.guardAggregateKey(deviceId, it.windowStartMs)
            }
            // Not eventTimestamp(): its fallback stamps the admin-disable time, which is not this event's.
            TYPE_BLOCK_BYPASS -> TamperAlertDedupe.blockBypassKey(deviceId, app, layout, inputData.getLong(KEY_EVENT_AT_MS, 0L))
            else -> null
        }
        // The window key is stable across attempts; the local key adds the count so attempt N+1 is
        // posted and a WorkManager retry of attempt N is not.
        val postKey = if (type == TYPE_GUARD_TRIGGERED && guardWindow != null) {
            TamperAlertDedupe.guardPostKey(deviceId, guardWindow)
        } else {
            dedupeKey
        }
        val dispatcher = TamperAlertDispatcher(
            wasPosted = { TamperState.isTamperAlertPosted(applicationContext, it) },
            recordPosted = { TamperState.markTamperAlertPosted(applicationContext, it) },
        )
        return try {
            dispatcher.dispatch(postKey) {
                entry.apiService().postInternalAlert(
                    AlertDto(
                        childId = childId,
                        deviceId = deviceId,
                        severity = "critical",
                        category = "tamper",
                        title = TITLES[type] ?: "Protection was changed",
                        body = bodyFor(type, detail, guardWindow?.count),
                        metadata = metadataFor(type, app, layout),
                        dedupeKey = dedupeKey,
                        attemptCount = if (type == TYPE_GUARD_TRIGGERED) guardWindow?.count else null,
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
     * The remove-protection window computed by the guard. Work enqueued by a pre-#227 build (or a
     * malformed input) has no window and falls back to the old one-page-per-run behaviour.
     */
    private fun guardWindow(): GuardAttemptWindow.State? {
        if (inputData.getString(KEY_TYPE) != TYPE_GUARD_TRIGGERED) return null
        val start = inputData.getLong(KEY_WINDOW_START_MS, 0L)
        val count = inputData.getInt(KEY_ATTEMPT_COUNT, 0)
        if (start <= 0L || count <= 0) return null
        return GuardAttemptWindow.State(windowStartMs = start, count = count)
    }

    /** The first attempt keeps the specific screen detail; later attempts say how many there were. */
    private fun bodyFor(type: String, detail: String, attemptCount: Int?): String = when {
        type == TYPE_GUARD_TRIGGERED && attemptCount != null && attemptCount > 1 ->
            "$attemptCount attempts were made to open a protection-removal screen on this device in 5 minutes. " +
                "The PIN was asked for each time."
        else -> detail.ifBlank { BODIES[type] ?: "" }
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
        const val TYPE_BLOCK_BYPASS = "block_bypass"
        private const val KEY_TYPE = "type"
        private const val KEY_DETAIL = "detail"
        private const val KEY_EVENT_AT_MS = "event_at_ms"
        private const val KEY_WINDOW_START_MS = "window_start_ms"
        private const val KEY_ATTEMPT_COUNT = "attempt_count"
        private const val KEY_APP = "app"
        private const val KEY_LAYOUT = "layout"
        private const val TAG = "TamperAlertWorker"

        private val TITLES = mapOf(
            TYPE_ADMIN_REMOVED to "Device admin was removed",
            TYPE_GUARD_TRIGGERED to "Someone tried to remove protection",
            TYPE_VPN_REVOKED to "Content filter was disconnected",
            TYPE_BLOCK_BYPASS to "A blocked app stayed on screen",
        )
        private val BODIES = mapOf(
            TYPE_ADMIN_REMOVED to "OSRA's device-admin rights were turned off on this device. Uninstall is no longer blocked.",
            TYPE_GUARD_TRIGGERED to "A protection-removal screen was opened on this device and the PIN was asked for.",
            TYPE_VPN_REVOKED to "OSRA's web filter (VPN) was disconnected on this device — another VPN app took over or it was turned off in Settings. Web filtering is off until it is reconnected.",
            TYPE_BLOCK_BYPASS to "A blocked app stayed visible in picture-in-picture or split screen after the block screen was shown twice.",
        )

        /** Issue #175: a block bypass also names the app and the layout, so the parent knows what stayed on screen. */
        internal fun metadataFor(type: String, app: String, layout: String): Map<String, String> =
            if (type == TYPE_BLOCK_BYPASS) mapOf("type" to type, "app" to app, "layout" to layout)
            else mapOf("type" to type)

        /**
         * Enqueues one expedited alert of [type]; a second enqueue of the same type replaces the
         * first. For [TYPE_GUARD_TRIGGERED], [windowStartMs] and [attemptCount] identify the
         * per-window aggregate row and its count (issue #227).
         */
        /**
         * Issue #227 D1 (Claude's review): one unique name per type meant a new window's enqueue
         * **cancelled the previous window's pending retry**, so attempts made while the phone was
         * offline were dropped as soon as the child tried again in the next window. Guard alerts are
         * therefore unique per window: REPLACE still coalesces inside a window (newest count wins),
         * and a new window no longer cancels the old one. Every other type keeps the old name.
         */
        internal fun uniqueWorkName(type: String, windowStartMs: Long, app: String = ""): String = when {
            type == TYPE_GUARD_TRIGGERED && windowStartMs > 0L -> "tamper_alert_${type}_$windowStartMs"
            // Issue #175: one bypass per episode; a second app's episode must not cancel the first's retry.
            type == TYPE_BLOCK_BYPASS -> "tamper_alert_${type}_${app}_$windowStartMs"
            else -> "tamper_alert_$type"
        }

        fun enqueue(
            context: Context,
            type: String,
            detail: String = "",
            eventAtMs: Long = 0L,
            windowStartMs: Long = 0L,
            attemptCount: Int = 0,
            app: String = "",
            layout: String = "",
        ) {
            val request = OneTimeWorkRequestBuilder<TamperAlertWorker>()
                .setExpedited(OutOfQuotaPolicy.RUN_AS_NON_EXPEDITED_WORK_REQUEST)
                .setInputData(
                    workDataOf(
                        KEY_TYPE to type,
                        KEY_DETAIL to detail,
                        KEY_EVENT_AT_MS to eventAtMs,
                        KEY_WINDOW_START_MS to windowStartMs,
                        KEY_ATTEMPT_COUNT to attemptCount,
                        KEY_APP to app,
                        KEY_LAYOUT to layout,
                    ),
                )
                .build()
            WorkManager.getInstance(context).enqueueUniqueWork(uniqueWorkName(type, if (type == TYPE_BLOCK_BYPASS) eventAtMs else windowStartMs, app), ExistingWorkPolicy.REPLACE, request)
        }
    }
}
