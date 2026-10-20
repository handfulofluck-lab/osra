package com.familyshield.agent.commands

import android.Manifest
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.admin.DevicePolicyManager
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import android.util.Log
import androidx.core.app.NotificationCompat
import androidx.core.content.ContextCompat
import com.familyshield.agent.data.AgentSettings
import com.familyshield.agent.data.ConsentState
import com.familyshield.agent.data.RuleRepository
import com.familyshield.agent.network.ApiService
import com.familyshield.agent.services.LocationService
import com.familyshield.agent.services.LocationStartPolicy
import com.familyshield.agent.sos.SosActivity
import dagger.hilt.android.qualifiers.ApplicationContext
import javax.inject.Inject
import javax.inject.Singleton
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch

/**
 * Dispatches parent commands delivered over FCM: lock, unlock, ring, sos_clear,
 * rules_updated (forces a rule refresh), locate_now (immediate location ping),
 * pause_internet/resume_internet (Feature #11), bonus_time (Feature #10) and
 * wind_down (Feature #22).
 */
@Singleton
class CommandDispatcher @Inject constructor(
    @ApplicationContext private val context: Context,
    private val rules: RuleRepository,
    private val devicePolicyManager: DevicePolicyManager,
    private val consent: ConsentState,
    private val deviceAdmin: com.familyshield.agent.security.DeviceAdminManager,
    private val api: ApiService,
    private val settings: AgentSettings,
) {
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)
    private var windDownJob: Job? = null
    private val ackSender = CommandAckSender(
        send = { commandId, ack ->
            settings.deviceId()?.let { deviceId ->
                api.ackCommand(deviceId = deviceId, commandId = commandId, body = ack)
            }
        },
        log = { message, error -> Log.w(TAG, message, error) },
    )

    /**
     * Executes the command [type] with its string [data] payload; unknown types are ignored.
     *
     * [commandId] is the durable queue row (`DeviceCommand.id`) when the command came from a poll.
     * Issue #231: a command that runs is acked `ok` so `/commands/history` reaches `acked` instead
     * of staying `delivered`; what `ok` means per command is documented on [CommandAckPolicy], and
     * `locate_now` defers its ack to [LocationService], which is the only place that knows a fix
     * was obtained. A refused or throwing handler is acked `failed` with `detail.reason`.
     */
    fun dispatch(type: String, data: Map<String, String>, commandId: String? = null) {
        // ADR-0008 §3: consent lifecycle commands pause/resume the whole agent.
        if (consent.onCommand(type)) {
            if (consent.isPaused()) {
                windDownJob?.cancel(); windDownJob = null
                rules.setPausedInternet(false)
            } else {
                rules.refreshAsync()
            }
            reportOutcome(commandId, CommandOutcome.Applied())
            return
        }
        val outcome = CommandAckPolicy.outcomeOf(
            { runHandler(type, data, commandId) },
            onFailure = { Log.w(TAG, "command '$type' failed", it) },
        )
        reportOutcome(commandId, outcome)
    }

    /** Runs one handler and says what the ack should claim; an unknown type stays unaudited. */
    private fun runHandler(type: String, data: Map<String, String>, commandId: String?): CommandOutcome =
        when (type) {
            "lock" -> { lock(); CommandOutcome.Applied() }
            "unlock" -> { unlock(); CommandOutcome.Applied() }
            // NOTE: pause/resume reuse the overlay mechanics with paused messaging —
            // a paused device shows the full-screen overlay until resumed.
            "pause" -> { pause(); CommandOutcome.Applied() }
            "resume" -> { unlock(); CommandOutcome.Applied() }
            "ring" -> { ring(); CommandOutcome.Applied() }
            "sos_clear" -> { sosClear(); CommandOutcome.Applied() }
            "stop_ring" -> { Ringer.stop(context, RingPolicy.StopSource.PARENT_COMMAND); CommandOutcome.Applied() }
            // Issue #231: the refresh is accepted here, not awaited. refresh() has no failure signal
            // (it falls back to the cached set), so "ok" claims the request was taken up, not that
            // new rules arrived.
            "rules_updated" -> { scope.launch { rules.refresh() }; CommandOutcome.Applied() }
            // Issue #231: starting the service is not a fix — LocationService acks once it has one.
            "locate_now" -> locateNow(commandId)
            // Feature #11: pause the internet — block everything except alwaysAllowedApps and
            // keep the overlay up until resume_internet arrives.
            "pause_internet" -> { pauseInternet(); CommandOutcome.Applied() }
            "resume_internet" -> { resumeInternet(); CommandOutcome.Applied() }
            // Feature #10: grant N extra screen-time minutes for today only.
            "bonus_time" -> dispatchMinutes(data) { rules.addBonusMinutes(it) }
            // Feature #22: warn, then lock after N minutes. Issue #231: the ack claims the warning
            // is posted and the timer armed, not that the lock has fired — the parent asked for the
            // warning, and waiting minutes for the timer would leave the row `delivered` meanwhile.
            "wind_down" -> dispatchMinutes(data) { windDown(it) }
            else -> CommandOutcome.Ignored // NOTE: unknown command types are ignored by design
        }

    /**
     * Parses and validates the minutes payload: tolerates "30" and "30.0" (the poll worker
     * stringifies JSON numbers), clamps to 1..240, and returns null for anything unparseable
     * or out of range — invalid values are ignored with a log rather than applied (and are not
     * acked: nothing ran, same as before #231).
     */
    private fun dispatchMinutes(data: Map<String, String>, action: (Int) -> Unit): CommandOutcome {
        val raw = data["minutes"]
        val minutes = parseMinutes(raw)
        if (minutes == null) {
            Log.w(TAG, "ignoring command: invalid minutes payload '$raw' (expected 1..240)")
            return CommandOutcome.Ignored
        }
        action(minutes)
        return CommandOutcome.Applied()
    }

    /** Sends at most one ack for [outcome]; a blank id (the FCM path) has no durable row. */
    private fun reportOutcome(commandId: String?, outcome: CommandOutcome) {
        val id = commandId?.takeIf { it.isNotBlank() } ?: return
        val ack = CommandAckPolicy.ackFor(id, outcome) ?: return
        scope.launch { ackSender.sendOnce(id, ack) }
    }

    /**
     * Issue #231: the deferred `locate_now` ack. Called by [LocationService] once it has (or has
     * not) obtained a fix, so `ok` means "the parent can see where the child is", not "the service
     * was asked to start".
     */
    fun ackLocateNow(commandId: String?, fix: LocateFix?) {
        val id = commandId?.takeIf { it.isNotBlank() } ?: return
        val ack = CommandAckPolicy.locateAck(id, fix) ?: return
        scope.launch { ackSender.sendOnce(id, ack) }
    }

    /** Locks the device immediately when device owner, otherwise shows the full-screen overlay. */
    private fun lock() {
        // ADR-0010: a real screen lock when admin/owner permits it; the overlay stays up either way
        // so the child sees the "locked by your parent" screen and cannot swipe back to their apps.
        com.familyshield.agent.enforcement.LockState.set(context, LockActivity.MODE_LOCKED)
        deviceAdmin.lockNow()
        context.startActivity(
            Intent(context, LockActivity::class.java)
                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                .putExtra(LockActivity.EXTRA_MODE, LockActivity.MODE_LOCKED),
        )
    }

    /** Shows the paused overlay (never device-owner lockNow — pause must be resumable via "resume"). */
    private fun pause() {
        com.familyshield.agent.enforcement.LockState.set(context, LockActivity.MODE_PAUSED)
        context.startActivity(
            Intent(context, LockActivity::class.java)
                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                .putExtra(LockActivity.EXTRA_MODE, LockActivity.MODE_PAUSED),
        )
    }

    /** Dismisses the keyguard via LockActivity (device-owner devices unlock with lockNow+swipe) and cancels any pending wind-down. */
    private fun unlock() {
        windDownJob?.cancel()
        windDownJob = null
        com.familyshield.agent.enforcement.LockState.clear(context)
        context.startActivity(
            Intent(context, LockActivity::class.java)
                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                .putExtra(LockActivity.EXTRA_MODE, LockActivity.MODE_UNLOCK),
        )
    }

    /**
     * Enables pause-the-internet (Feature #11): RuleRepository blocks every app except
     * alwaysAllowedApps and the overlay stays up until resume_internet.
     * Plan 1.4: when the parent granted the VPN consent, the sinkhole also takes the default
     * route and drops every packet that is not from an always-allowed app, so "paused" holds
     * even for an app the accessibility monitor never sees (background sync, a game's own
     * network stack). Without the consent the overlay plus app blocking is what enforces it.
     */
    private fun pauseInternet() {
        rules.setPausedInternet(true)
        com.familyshield.agent.enforcement.LockState.set(context, LockActivity.MODE_PAUSED_INTERNET)
        if (com.familyshield.agent.vpn.VpnState.isEnabled(context)) {
            runCatching { com.familyshield.agent.vpn.FilterVpnService.start(context, com.familyshield.agent.vpn.FilterVpnService.MODE_SINKHOLE_ALL) }
        }
        context.startActivity(
            Intent(context, LockActivity::class.java)
                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                .putExtra(LockActivity.EXTRA_MODE, LockActivity.MODE_PAUSED_INTERNET),
        )
    }

    /** Clears pause-the-internet and dismisses the paused-internet overlay (single-task onNewIntent). */
    private fun resumeInternet() {
        rules.setPausedInternet(false)
        com.familyshield.agent.enforcement.LockState.clear(context)
        if (com.familyshield.agent.vpn.VpnState.isEnabled(context)) {
            runCatching { com.familyshield.agent.vpn.FilterVpnService.start(context, com.familyshield.agent.vpn.FilterVpnService.MODE_DNS) }
        }
        context.startActivity(
            Intent(context, LockActivity::class.java)
                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                .putExtra(LockActivity.EXTRA_MODE, LockActivity.MODE_DISMISS),
        )
    }

    /**
     * Wind-down (Feature #22): posts a heads-up notification that the screen will lock in
     * [minutes], then locks after the delay. A new wind_down replaces the pending one and
     * unlock cancels it (job cancellation on unlock).
     * NOTE: the delay is Android-timed (coroutine + delay), which is not unit-testable on the
     * JVM — scheduling correctness is covered by inspection, not tests.
     */
    private fun windDown(minutes: Int) {
        postWindDownNotification(minutes)
        windDownJob?.cancel()
        windDownJob = scope.launch {
            delay(minutes.toLong() * 60_000L)
            lock()
        }
    }

    /** Shows the "Screen will lock in N minutes" heads-up notification (IMPORTANCE_HIGH channel). */
    private fun postWindDownNotification(minutes: Int) {
        runCatching {
            val nm = context.getSystemService(NotificationManager::class.java) ?: return
            nm.createNotificationChannel(
                NotificationChannel(CHANNEL_COMMANDS, "Parent commands", NotificationManager.IMPORTANCE_HIGH),
            )
            val notification = NotificationCompat.Builder(context, CHANNEL_COMMANDS)
                .setSmallIcon(android.R.drawable.ic_dialog_info)
                .setContentTitle("Screen time ending")
                .setContentText("Screen will lock in $minutes minutes")
                .setPriority(NotificationCompat.PRIORITY_HIGH)
                .setCategory(NotificationCompat.CATEGORY_REMINDER)
                .setAutoCancel(true)
                .build()
            nm.notify(WIND_DOWN_NOTIFICATION_ID, notification)
        }
    }

    /** Rings the alarm stream at full volume until stopped or after 60 s. */
    /** Plan 1.7: the ring is [Ringer] — max alarm volume, screen on, stop needs the parent PIN or a parent command. */
    private fun ring() {
        Ringer.start(context)
    }

    /** Stops any active ring and dismisses the SOS screen (parent-side sos_clear, Feature #14). */
    private fun sosClear() {
        Ringer.stop(context, RingPolicy.StopSource.PARENT_COMMAND)
        // NOTE: single-task SosActivity re-delivers via onNewIntent and finishes on EXTRA_DISMISS.
        context.startActivity(
            Intent(context, SosActivity::class.java)
                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                .putExtra(SosActivity.EXTRA_DISMISS, true),
        )
    }

    /**
     * Asks LocationService for an immediate ping + flush.
     *
     * Issue #132: a poll or FCM delivery is a background context, so the location foreground service
     * needs the background grant — fine/coarse alone is while-in-use. Starting it anyway is the
     * #128 failure in this call site: Android 14+ refuses `startForeground()`, and at best
     * `locate_now` dies silently with the parent told nothing. The guard runs first and the refusal
     * becomes a `failed` command ack keyed by [LocationStartPolicy.Decision.reason], so
     * `/v1/devices/:id/commands/history` says `failed` with `detail.reason` instead of the command
     * looking merely undelivered.
     *
     * Issue #231: on a successful start the outcome is [CommandOutcome.Deferred], not `ok`.
     * [LocationService] carries the row id through the intent and acks `ok` only after it has a
     * fresh or recent cached fix, so `acked` in the parent's history means the map can move.
     */
    private fun locateNow(commandId: String?): CommandOutcome {
        val decision = locateNowDecision(
            hasFineLocation = granted(Manifest.permission.ACCESS_FINE_LOCATION),
            hasCoarseLocation = granted(Manifest.permission.ACCESS_COARSE_LOCATION),
            hasBackgroundLocation = granted(Manifest.permission.ACCESS_BACKGROUND_LOCATION),
            apiLevel = Build.VERSION.SDK_INT,
        )
        if (decision != LocationStartPolicy.Decision.START) {
            val reason = decision.reason ?: CommandAckPolicy.REASON_LOCATION_UNAVAILABLE
            Log.w(
                TAG,
                "locate_now refused: $reason — a location foreground service started from the background " +
                    "needs fine or coarse location and, on Android 10+, \"Location (allow all the time)\"",
            )
            return CommandOutcome.Refused(reason)
        }
        return try {
            // NOTE: must be startForegroundService — LocationService calls startForeground() in
            // onStartCommand, and a plain startService() from the background (FCM/worker context)
            // throws IllegalStateException on API 26+, silently killing locate_now.
            ContextCompat.startForegroundService(
                context,
                Intent(context, LocationService::class.java)
                    .setAction(LocationService.ACTION_PING_NOW)
                    .putExtra(LocationService.EXTRA_COMMAND_ID, commandId),
            )
            CommandOutcome.Deferred
        } catch (e: Exception) {
            // The OS refused the start after the grants looked right (API 31+ background-start
            // restriction, or permission revoked in between). Say so rather than swallow it.
            Log.w(TAG, "locate_now: the OS refused to start LocationService", e)
            CommandOutcome.Refused("foreground_service_start_failed")
        }
    }

    private fun granted(permission: String): Boolean =
        ContextCompat.checkSelfPermission(context, permission) == PackageManager.PERMISSION_GRANTED

    companion object {
        private const val TAG = "CommandDispatcher"
        private const val CHANNEL_COMMANDS = "commands"
        private const val WIND_DOWN_NOTIFICATION_ID = 42
        private const val MIN_MINUTES = 1
        private const val MAX_MINUTES = 240

        /**
         * Issue #132: the `locate_now` pre-start gate, pure so the JVM suite holds it. A refused
         * command reports [LocationStartPolicy.Decision.reason] to the server instead of failing
         * silently.
         */
        internal fun locateNowDecision(
            hasFineLocation: Boolean,
            hasCoarseLocation: Boolean,
            hasBackgroundLocation: Boolean,
            apiLevel: Int,
        ): LocationStartPolicy.Decision = LocationStartPolicy.decide(
            hasFineLocation = hasFineLocation,
            hasCoarseLocation = hasCoarseLocation,
            hasBackgroundLocation = hasBackgroundLocation,
            apiLevel = apiLevel,
        )

        /**
         * Pure minutes parser for command payloads: returns the clamped value in 1..240, or null
         * when [raw] is missing or not a number.
         */
        internal fun parseMinutes(raw: String?): Int? =
            raw?.toDoubleOrNull()?.toInt()?.coerceIn(MIN_MINUTES, MAX_MINUTES)
    }
}
