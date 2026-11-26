package com.familyshield.agent.security

import android.content.Context
import android.util.Log
import androidx.work.Constraints
import androidx.work.CoroutineWorker
import androidx.work.ExistingWorkPolicy
import androidx.work.NetworkType
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
        // Issue #1174 / Ahmed acceptance (7200575366): no tamper alert fires before initial setup
        // completes once; only the deduplicated TYPE_SETUP_INCOMPLETE notice is allowed mid-setup.
        if (type != TYPE_SETUP_INCOMPLETE &&
            !com.familyshield.agent.setup.SetupCompletionStore.isCompletedForDevice(applicationContext, deviceId)
        ) {
            return Result.success()
        }
        val guardWindow = guardWindow()
        val dedupeKey = dedupeKeyFor(
            type = type,
            deviceId = deviceId,
            guardWindow = guardWindow,
            app = app,
            layout = layout,
            // The block-bypass and unbind keys use the event's own time, never eventTimestamp(): its fallback
            // stamps the admin-disable time, which is not this event's.
            eventAtMs = inputData.getLong(KEY_EVENT_AT_MS, 0L),
            adminRemovedAtMs = eventTimestamp(),
            // #792 B1: the count is part of the lockout key, so attempt N+1 is posted and a WorkManager retry of
            // attempt N is not.
            attemptCount = inputData.getInt(KEY_ATTEMPT_COUNT, 0),
        )
        // The window key is stable across attempts; the local key adds the count so attempt N+1 is
        // posted and a WorkManager retry of attempt N is not.
        val postKey = when {
            type == TYPE_GUARD_TRIGGERED && guardWindow != null ->
                TamperAlertDedupe.guardPostKey(deviceId, guardWindow)
            type == TYPE_SETUP_INCOMPLETE && dedupeKey != null ->
                "$dedupeKey:${app.ifBlank { detail }}"
            else -> dedupeKey
        }
        val dispatcher = TamperAlertDispatcher(
            wasPosted = { TamperState.isTamperAlertPosted(applicationContext, it) },
            recordPosted = { TamperState.markTamperAlertPosted(applicationContext, it) },
        )
        return try {
            // U2b (Antigravity): written here, before the POST, so the 60-second poll reads the same event as
            // already reported. Doing it in onUnbind raced a scope that onDestroy cancels.
            if (type == TYPE_ACCESSIBILITY_OFF && runAttemptCount == 0) {
                runCatching {
                    settings.recordAccessibilityEnabled(false)
                    settings.recordTamperAlert(com.familyshield.agent.receivers.AccessibilityOffPolicy.TYPE, inputData.getLong(KEY_EVENT_AT_MS, 0L))
                }
            }
            dispatcher.dispatch(postKey) {
                entry.apiService().postInternalAlert(
                    AlertDto(
                        childId = childId,
                        deviceId = deviceId,
                        severity = if (type == TYPE_SETUP_INCOMPLETE) "warning" else "critical",
                        category = "tamper",
                        title = TITLES[type] ?: "Protection was changed",
                        body = bodyFor(type, detail, guardWindow),
                        metadata = metadataFor(type, app, layout),
                        dedupeKey = dedupeKey,
                        attemptCount = when (type) {
                            TYPE_GUARD_TRIGGERED -> guardWindow?.count
                            TYPE_PIN_LOCKOUT -> inputData.getInt(KEY_ATTEMPT_COUNT, 0).takeIf { it > 0 }
                            else -> null
                        },
                    ),
                )
            }
            if (type == TYPE_ADMIN_REMOVED) TamperState.setAdminDisabledPending(applicationContext, false)
            Result.success()
        } catch (e: Exception) {
            Log.w(TAG, "tamper alert '$type' failed; retrying", e)
            // osra-security#29 review (Claude): the unbind alert never gives up. The poll cannot take over — the
            // state is written before the POST — so a capped retry would mean an offline phone tells nobody. The
            // dedupe key makes a repeat safe.
            if (shouldRetry(type, runAttemptCount)) Result.retry() else Result.failure()
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
        val screens = GuardAttemptWindow.decodeScreens(inputData.getString(KEY_SCREENS))
        return GuardAttemptWindow.State(windowStartMs = start, count = count, screens = screens)
    }

    /** The first attempt keeps the specific screen detail; later ones give the count and every screen tried. */

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
        /**
         * osra-security#24 / #792, Antigravity B1: a PIN lockout is its own alert, not a protection-screen
         * attempt. Sharing [TYPE_GUARD_TRIGGERED] made [bodyFor] replace the lockout sentence with the
         * five-attempt aggregation whenever the count reached five, so the parent never read the duration.
         */
        const val TYPE_PIN_LOCKOUT = "parent_pin_locked"
        const val TYPE_VPN_REVOKED = "content_filter_disconnected"

        /** osra-security#29, second half: the accessibility service was unbound while paired. */
        const val TYPE_ACCESSIBILITY_OFF = "accessibility_off"
        const val TYPE_BLOCK_BYPASS = "block_bypass"
        /** Issue #1174: paired phone has not finished required onboarding permissions yet. */
        const val TYPE_SETUP_INCOMPLETE = "setup_incomplete_permissions"
        private const val KEY_TYPE = "type"
        private const val KEY_DETAIL = "detail"
        private const val KEY_EVENT_AT_MS = "event_at_ms"
        private const val KEY_WINDOW_START_MS = "window_start_ms"
        private const val KEY_ATTEMPT_COUNT = "attempt_count"
        private const val KEY_APP = "app"
        private const val KEY_LAYOUT = "layout"
        private const val KEY_SCREENS = "screens"
        private const val TAG = "TamperAlertWorker"

        private val TITLES = mapOf(
            TYPE_ADMIN_REMOVED to "Device admin was removed",
            TYPE_GUARD_TRIGGERED to "Someone tried to remove protection",
            TYPE_VPN_REVOKED to "Content filter was disconnected",
            TYPE_ACCESSIBILITY_OFF to "Protection was disabled",
            TYPE_BLOCK_BYPASS to "A blocked app stayed on screen",
            TYPE_PIN_LOCKOUT to "Too many wrong parent-PIN tries",
            TYPE_SETUP_INCOMPLETE to "Setup is not finished yet",
        )
        private val BODIES = mapOf(
            TYPE_ACCESSIBILITY_OFF to "The OSRA accessibility service was turned off on this device",
            TYPE_ADMIN_REMOVED to "OSRA's device-admin rights were turned off on this device. Uninstall is no longer blocked.",
            TYPE_GUARD_TRIGGERED to "A protection-removal screen was opened on this device and the PIN was asked for.",
            TYPE_VPN_REVOKED to "OSRA's web filter (VPN) was disconnected on this device — another VPN app took over or it was turned off in Settings. Web filtering is off until it is reconnected.",
            TYPE_BLOCK_BYPASS to "A blocked app stayed visible in picture-in-picture or split screen after the block screen was shown twice.",
            TYPE_SETUP_INCOMPLETE to "Some required permissions are still missing on this device. Protection will start once setup finishes.",
        )

        /** Issue #175: a block bypass also names the app and the layout, so the parent knows what stayed on screen. */
        internal fun metadataFor(type: String, app: String, layout: String): Map<String, String> = when (type) {
            TYPE_BLOCK_BYPASS -> mapOf("type" to type, "app" to app, "layout" to layout)
            TYPE_SETUP_INCOMPLETE -> mapOf("type" to type, "missingGrants" to app)
            else -> mapOf("type" to type)
        }

        /**
         * #813 review (Claude): the dedupe key as a pure function, so a test can drive it. It used to be computed
         * inline, and a row that only read the source could not tell a deleted branch from a wired one — the two
         * types below were exactly that mistake.
         */
        internal fun dedupeKeyFor(
            type: String,
            deviceId: String?,
            guardWindow: GuardAttemptWindow.State?,
            app: String,
            layout: String,
            eventAtMs: Long,
            adminRemovedAtMs: Long,
            attemptCount: Int = 0,
        ): String? = when (type) {
            TYPE_ADMIN_REMOVED -> TamperAlertDedupe.adminRemovalKey(deviceId, adminRemovedAtMs)
            TYPE_GUARD_TRIGGERED -> guardWindow?.let { TamperAlertDedupe.guardAggregateKey(deviceId, it.windowStartMs) }
            TYPE_BLOCK_BYPASS -> TamperAlertDedupe.blockBypassKey(deviceId, app, layout, eventAtMs)
            TYPE_ACCESSIBILITY_OFF -> TamperAlertDedupe.accessibilityOffKey(deviceId, eventAtMs)
            // #792 B1, landed with the #813 fold as Claude and Antigravity asked: a lockout key carries the instant
            // and the count, so the next lockout is a new key and a retry of this one is not.
            TYPE_PIN_LOCKOUT -> TamperAlertDedupe.pinLockoutKey(deviceId, eventAtMs, attemptCount)
            TYPE_SETUP_INCOMPLETE -> deviceId?.takeIf { it.isNotBlank() }?.let { "setup_incomplete:$it" }
            else -> null
        }

        /**
         * Whether failing attempt N is worth another try. The unbind alert never gives up: the poll reads the state
         * this worker writes, so a capped retry would leave an offline phone telling nobody.
         */
        internal fun shouldRetry(type: String, runAttemptCount: Int): Boolean =
            type == TYPE_ACCESSIBILITY_OFF || runAttemptCount < MAX_ATTEMPTS_PER_ALERT

        /** How many times an ordinary tamper alert retries before giving up. */
        internal const val MAX_ATTEMPTS_PER_ALERT = 5

        /**
         * Issue #227 D1 (Claude's review): one unique name per type meant a new window's enqueue
         * **cancelled the previous window's pending retry**, so attempts made while the phone was
         * offline were dropped as soon as the child tried again in the next window. Guard alerts are
         * therefore unique per window: REPLACE still coalesces inside a window (newest count wins),
         * and a new window no longer cancels the old one. Every other type keeps the old name.
         */
        /**
         * The sentence the parent reads. #792 (Antigravity B1): a \`TYPE_PIN_LOCKOUT\` never reaches
         * [GuardAttemptWindow.body], which ignores the detail above a count of one and would replace the
         * lockout sentence with the protection-screen aggregation.
         */
        internal fun bodyFor(type: String, detail: String, window: GuardAttemptWindow.State?): String = when {
            type == TYPE_GUARD_TRIGGERED && window != null && window.count > 1 ->
                GuardAttemptWindow.body(window.count, window.screens, detail)
            else -> detail.ifBlank { BODIES[type] ?: "" }
        }

        internal fun uniqueWorkName(type: String, windowStartMs: Long, app: String = ""): String = when {
            type == TYPE_GUARD_TRIGGERED && windowStartMs > 0L -> "tamper_alert_${type}_$windowStartMs"
            // Issue #175: one bypass per episode; a second app's episode must not cancel the first's retry.
            type == TYPE_BLOCK_BYPASS -> "tamper_alert_${type}_${app}_$windowStartMs"
            // #792 B1: eventAtMs arrives as windowStartMs for this type; one work item per lockout.
            type == TYPE_PIN_LOCKOUT && windowStartMs > 0L -> "tamper_alert_${type}_$windowStartMs"
            // U1: one work item per unbind, so a second one cannot cancel the first one's retry.
            type == TYPE_ACCESSIBILITY_OFF && windowStartMs > 0L -> "tamper_alert_${type}_$windowStartMs"
            else -> "tamper_alert_$type"
        }

        /**
         * #792 (Antigravity B1, to land with the #813 fold as Claude ordered): which instant names the work item.
         * Three types carry their own event instant — the block bypass, the unbind (U1) and the lockout (B1);
         * everything else is aggregated by the guard window. `enqueue` read `windowStartMs` for every type but the
         * bypass, and `TamperGuardActivity` enqueues a lockout with `windowStartMs = 0L` — so every lockout shared
         * the static `tamper_alert_parent_pin_locked` name and a second lockout's `REPLACE` cancelled the first
         * one's pending offline retry, while the row that called [uniqueWorkName] directly stayed green.
         */
        internal fun workNameInstant(type: String, eventAtMs: Long, windowStartMs: Long): Long =
            if (type == TYPE_BLOCK_BYPASS || type == TYPE_PIN_LOCKOUT || type == TYPE_ACCESSIBILITY_OFF) {
                eventAtMs
            } else {
                windowStartMs
            }

        /**
         * Enqueues one expedited alert of [type]; a second enqueue of the same type replaces the
         * first. For [TYPE_GUARD_TRIGGERED], [windowStartMs] and [attemptCount] identify the
         * per-window aggregate row and its count (issue #227).
         */
        fun enqueue(
            context: Context,
            type: String,
            detail: String = "",
            eventAtMs: Long = 0L,
            windowStartMs: Long = 0L,
            attemptCount: Int = 0,
            screens: List<String> = emptyList(),
            app: String = "",
            layout: String = "",
        ) {
            val request = OneTimeWorkRequestBuilder<TamperAlertWorker>()
                // Review of osra-security#29 (Claude): without this the worker keeps failing while the phone is
                // offline, and with the capped exponential backoff the first successful attempt can land hours
                // after reconnect. A constraint makes WorkManager wait for the network instead of burning retries.
                .setConstraints(Constraints.Builder().setRequiredNetworkType(NetworkType.CONNECTED).build())
                .setExpedited(OutOfQuotaPolicy.RUN_AS_NON_EXPEDITED_WORK_REQUEST)
                .setInputData(
                    workDataOf(
                        KEY_TYPE to type,
                        KEY_DETAIL to detail,
                        KEY_EVENT_AT_MS to eventAtMs,
                        KEY_WINDOW_START_MS to windowStartMs,
                        KEY_ATTEMPT_COUNT to attemptCount,
                        KEY_SCREENS to GuardAttemptWindow.encodeScreens(screens),
                        KEY_APP to app,
                        KEY_LAYOUT to layout,
                    ),
                )
                .build()
            WorkManager.getInstance(context).enqueueUniqueWork(
                // U1 (Antigravity) for the unbind and #792 B1 for the lockout: without this both types passed 0L and
                // every event of the type collapsed onto one static work name, cancelling the previous one's retry.
                uniqueWorkName(type, workNameInstant(type, eventAtMs, windowStartMs), app),
                ExistingWorkPolicy.REPLACE,
                request,
            )
        }
    }
}
