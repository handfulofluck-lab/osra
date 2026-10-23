package com.familyshield.agent.commands

import android.Manifest
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.admin.DevicePolicyManager
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import android.provider.Settings
import android.util.Log
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationManagerCompat
import androidx.core.content.ContextCompat
import com.familyshield.agent.R
import com.familyshield.agent.data.AgentSettings
import com.familyshield.agent.data.ConsentState
import com.familyshield.agent.data.RuleRepository
import com.familyshield.agent.network.ApiService
import com.familyshield.agent.security.EnforceabilityPolicy
import com.familyshield.agent.services.AccessibilityMonitorService
import com.familyshield.agent.services.LocationService
import com.familyshield.agent.services.LocationStartPolicy
import com.familyshield.agent.sos.SosActivity
import dagger.hilt.android.qualifiers.ApplicationContext
import java.time.Instant
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
 * pause_internet/resume_internet (Feature #11), bonus_time (Feature #10),
 * wind_down (Feature #22) and show_reset_code (ADR-0031's family witness).
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
     * Executes the command [type] with its string [data] payload.
     *
     * [commandId] is the durable queue row (`DeviceCommand.id`) when the command came from a poll.
     * Issue #231: a command that runs is acked `ok` so `/commands/history` reaches `acked` instead
     * of staying `delivered`; what `ok` means per command is documented on [CommandAckPolicy], and
     * `locate_now` defers its ack to [LocationService], which is the only place that knows a fix
     * was obtained. A refused or throwing handler is acked `failed` with `detail.reason`.
     *
     * No durable row is left unaudited: an unknown type is `failed` with `unsupported_command`, an
     * unparseable minutes payload with `invalid_payload`, and `lock`/`pause` are `ok` only when
     * [EnforceabilityPolicy] finds a path that can actually show the screen. `unlock`/`resume` are
     * always `ok` and carry `detail.screen = dismissed|not_showing` instead (issue #233 review).
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

    /** Runs one handler and says what the ack should claim. Every outcome is acked or deferred. */
    private fun runHandler(type: String, data: Map<String, String>, commandId: String?): CommandOutcome =
        when (type) {
            "lock" -> lock()
            "unlock" -> unlock()
            // NOTE: pause/resume reuse the overlay mechanics with paused messaging —
            // a paused device shows the full-screen overlay until resumed.
            "pause" -> pause()
            "resume" -> unlock()
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
            "pause_internet" -> pauseInternet()
            "resume_internet" -> { resumeInternet(); CommandOutcome.Applied() }
            // Feature #10: grant N extra screen-time minutes for today only.
            "bonus_time" -> dispatchMinutes(data) { rules.addBonusMinutes(it) }
            // Feature #22: warn, then lock after N minutes. Issue #231: the ack claims the warning
            // is posted and the timer armed, not that the lock has fired — the parent asked for the
            // warning, and waiting minutes for the timer would leave the row `delivered` meanwhile.
            "wind_down" -> dispatchMinutes(data) { windDown(it) }
            // ADR-0031: the family witness. Deferred, not acked at display: see [showResetCode].
            "show_reset_code" -> showResetCode(data, commandId)
            // Issue #231 review: a type this agent does not know must not stay `delivered` forever.
            // `unsupported_command` lets the parent say "update OSRA on the child's phone".
            else -> {
                Log.w(TAG, "refusing unknown command type '$type'")
                unknownTypeOutcome()
            }
        }

    /**
     * Parses and validates the minutes payload: tolerates "30" and "30.0" (the poll worker
     * stringifies JSON numbers), clamps to 1..240, and refuses an unparseable value with
     * [invalidMinutesOutcome] instead of leaving the row unaudited.
     */
    private fun dispatchMinutes(data: Map<String, String>, action: (Int) -> Unit): CommandOutcome {
        val raw = data["minutes"]
        val minutes = parseMinutes(raw)
        if (minutes == null) {
            Log.w(TAG, "refusing command: invalid minutes payload '$raw' (expected 1..240)")
            return invalidMinutesOutcome()
        }
        action(minutes)
        return CommandOutcome.Applied()
    }

    /**
     * ADR-0031: show the 8-digit family-witness code, and keep it clearable.
     *
     * - **Empty payload** is the API's withdrawal (`clearResetCodePayloads` writes `payload = {}`):
     *   clear the notice if it is the same command row, cancel its notification and ack `ok` with
     *   `screen=withdrawn`. This is why the row is *not* acked at display: an ack clears the payload,
     *   and then there is no redelivery left to carry the withdrawal.
     * - **Malformed or expired payload** is a `failed` ack with the parser's reason; nothing is
     *   shown. Acking clears a credential that could not be used anyway.
     * - **Valid payload with nothing that can show it** — overlay app-op off, accessibility unbound
     *   and notifications disabled — is refused `reset_code_screen_unavailable` instead of leaving a
     *   silent row. The overlay or the bound accessibility service is what exempts the
     *   `startActivity` below from Android's background-activity-launch rule, exactly as for
     *   [lock]/[pause]; a notification needs no such exemption and covers a locked phone, so it counts
     *   as a way to show the code.
     * - **Valid payload** enters [ResetCodeState], a code-less notification is posted when
     *   notifications are allowed, and [ResetCodeActivity] is started when a background launch is
     *   allowed; the outcome is [CommandOutcome.Deferred] and the notice acks when it ends.
     *
     * The payload is never logged: it is the only place the plaintext code exists on this device.
     */
    private fun showResetCode(data: Map<String, String>, commandId: String?): CommandOutcome {
        val canLaunch = Settings.canDrawOverlays(context) || AccessibilityMonitorService.isRunning
        val canNotify = NotificationManagerCompat.from(context).areNotificationsEnabled()
        return when (val decision = ResetCodePolicy.decide(data, commandId, Instant.now(), canShowScreen = canLaunch || canNotify)) {
            is ResetCodeDecision.Refuse -> {
                Log.w(TAG, "show_reset_code refused: ${decision.reason}")
                CommandOutcome.Refused(decision.reason)
            }
            is ResetCodeDecision.Withdraw -> {
                ResetCodeState.clearIfCommand(decision.commandId)?.let { cancelResetCodeNotification() }
                CommandOutcome.Applied(ResetCodePolicy.ackDetail(ResetCodeEnd.WITHDRAWN))
            }
            is ResetCodeDecision.Show -> {
                val previous = ResetCodeState.show(decision.notice)
                if (previous != null && previous.commandId != decision.notice.commandId) {
                    // Only one code is on screen. The replaced row is acked so it does not sit
                    // delivered; acking also clears its plaintext, which nothing is showing now.
                    reportOutcome(previous.commandId, CommandOutcome.Applied(ResetCodePolicy.ackDetail(ResetCodeEnd.SUPERSEDED)))
                }
                // The notification never carries the code, so it may sit on the lock screen: it is
                // what a child sees on a locked phone, and the only way in when no background launch
                // is allowed.
                if (canNotify) postResetCodeNotification(decision.notice)
                if (canLaunch) {
                    context.startActivity(
                        Intent(context, ResetCodeActivity::class.java)
                            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK),
                    )
                }
                CommandOutcome.Deferred
            }
        }
    }

    /** ADR-0031: "a code for your parent is waiting". Never the code itself. */
    private fun postResetCodeNotification(notice: ResetCodeNotice) {
        runCatching {
            val nm = context.getSystemService(NotificationManager::class.java) ?: return@runCatching
            nm.createNotificationChannel(
                NotificationChannel(CHANNEL_COMMANDS, "Parent commands", NotificationManager.IMPORTANCE_HIGH),
            )
            val open = PendingIntent.getActivity(
                context,
                RESET_CODE_NOTIFICATION_ID,
                Intent(context, ResetCodeActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK),
                PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
            )
            val notification = NotificationCompat.Builder(context, CHANNEL_COMMANDS)
                .setSmallIcon(android.R.drawable.ic_dialog_info)
                .setContentTitle(context.getString(R.string.reset_code_title))
                .setContentText(context.getString(R.string.reset_code_notification_text))
                .setPriority(NotificationCompat.PRIORITY_HIGH)
                .setCategory(NotificationCompat.CATEGORY_REMINDER)
                .setContentIntent(open)
                .setAutoCancel(true)
                .setOnlyAlertOnce(true) // the 120-second redelivery re-posts the same notification quietly
                .setTimeoutAfter(ResetCodePolicy.remaining(notice.expiresAt, Instant.now()).toMillis())
                .build()
            nm.notify(RESET_CODE_NOTIFICATION_ID, notification)
        }
    }

    private fun cancelResetCodeNotification() {
        runCatching { NotificationManagerCompat.from(context).cancel(RESET_CODE_NOTIFICATION_ID) }
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
     * was asked to start". [uploaded] is [LocationService.flushPings]'s result: a fix that only sits
     * in the phone's buffer is not observable, so no ack is sent and the row is re-offered at 120 s.
     */
    fun ackLocateNow(commandId: String?, fix: LocateFix?, uploaded: Boolean) {
        val id = commandId?.takeIf { it.isNotBlank() } ?: return
        val ack = CommandAckPolicy.locateAck(id, fix, uploaded) ?: return
        scope.launch { ackSender.sendOnce(id, ack) }
    }

    /**
     * ADR-0031: the deferred `show_reset_code` ack, sent by [ResetCodeActivity] when the notice ends.
     * Same shape as [ackLocateNow]: `ok` means the notice was on screen, `detail.screen` how it ended
     * (`expired`, `dismissed`). `superseded` is acked here by [showResetCode] instead, because it is
     * the dispatcher — not the screen — that replaces one code with another.
     */
    fun ackResetCode(commandId: String?, end: ResetCodeEnd) {
        reportOutcome(commandId, CommandOutcome.Applied(ResetCodePolicy.ackDetail(end)))
    }

    /**
     * Locks the device immediately when device owner, otherwise shows the full-screen overlay.
     *
     * Issue #231 review D1: `startActivity` does not fail when the OS blocks a background launch, so
     * the ack is decided by [EnforceabilityPolicy] from the paths that can actually lock, not by the
     * handler returning. `LockState` is written first in every case — including a refusal — so the
     * lock lands the moment the parent grants overlay or accessibility.
     */
    private fun lock(): CommandOutcome {
        // ADR-0010: a real screen lock when admin/owner permits it; the overlay stays up either way
        // so the child sees the "locked by your parent" screen and cannot swipe back to their apps.
        com.familyshield.agent.enforcement.LockState.set(context, LockActivity.MODE_LOCKED)
        val adminLocked = deviceAdmin.lockNow()
        val outcome = EnforceabilityPolicy.lockOutcome(
            canOverlay = Settings.canDrawOverlays(context),
            accessibilityRunning = AccessibilityMonitorService.isRunning,
            adminLocked = adminLocked,
        )
        // Best effort in the refused case too: if the policy is wrong about the OS, the attempt costs
        // nothing and the persisted LockState still applies when a grant returns.
        context.startActivity(
            Intent(context, LockActivity::class.java)
                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                .putExtra(LockActivity.EXTRA_MODE, LockActivity.MODE_LOCKED),
        )
        return outcome
    }

    /**
     * Shows the paused overlay (never device-owner lockNow — pause must be resumable via "resume").
     * Same D1 rule as [lock]: `Applied` only when the overlay can actually appear.
     */
    private fun pause(): CommandOutcome {
        com.familyshield.agent.enforcement.LockState.set(context, LockActivity.MODE_PAUSED)
        val outcome = EnforceabilityPolicy.pauseOutcome(
            canOverlay = Settings.canDrawOverlays(context),
            accessibilityRunning = AccessibilityMonitorService.isRunning,
        )
        context.startActivity(
            Intent(context, LockActivity::class.java)
                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                .putExtra(LockActivity.EXTRA_MODE, LockActivity.MODE_PAUSED),
        )
        return outcome
    }

    /**
     * Dismisses the overlay via [LockActivity] and cancels any pending wind-down. `resume` shares
     * this call: a paused device shows the same overlay, so it is dismissed the same way.
     *
     * Issue #233 review (F1/F2): `LockState` is cleared first, then the outcome depends on whether
     * [LockActivity] is on screen. When it is, our own visible window is what lets Android start the
     * activity from the background (`BAL_ALLOW_VISIBLE_WINDOW`), even with overlay and accessibility
     * off — so the launch happens and the screen goes away. When it is not, there is nothing to take
     * down and a blind launch would only create the blocked activity record whose replayed
     * `MODE_UNLOCK` finished a later `lock` (F2), so no launch is made. Either way the ack is `ok`
     * with `detail.screen = dismissed|not_showing`: a refusal here fired exactly when the unlock had
     * worked, telling the parent the phone was still covered.
     */
    private fun unlock(): CommandOutcome {
        windDownJob?.cancel()
        windDownJob = null
        com.familyshield.agent.enforcement.LockState.clear(context)
        val showing = LockActivity.isShowing
        if (showing) {
            context.startActivity(
                Intent(context, LockActivity::class.java)
                    .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                    .putExtra(LockActivity.EXTRA_MODE, LockActivity.MODE_UNLOCK),
            )
        }
        return EnforceabilityPolicy.unlockOutcome(lockScreenShowing = showing)
    }

    /**
     * Enables pause-the-internet (Feature #11): RuleRepository blocks every app except
     * alwaysAllowedApps and the overlay stays up until resume_internet.
     * Plan 1.4: when the parent granted the VPN consent, the sinkhole also takes the default
     * route and drops every packet that is not from an always-allowed app, so "paused" holds
     * even for an app the accessibility monitor never sees (background sync, a game's own
     * network stack).
     *
     * Issue #231 review D2: without the consent the overlay and app blocking do not stop packets,
     * so `ok` would be false (measured: `ping 8.8.8.8` still answered after an acked pause). The
     * refusal is [EnforceabilityPolicy.REASON_WEB_FILTER_NOT_SET_UP]; the paused state is persisted
     * anyway so the pause applies once the filter is set up.
     *
     * "Set up" is the stored consent **and** the OS still allowing the tunnel
     * ([com.familyshield.agent.vpn.FilterVpnService.isPrepared]): `VpnState.isEnabled` is only ever
     * set true, so a consent revoked in Settings would otherwise leave the flag saying yes while
     * `FilterVpnService.start` silently returns and no packet is dropped.
     */
    private fun pauseInternet(): CommandOutcome {
        rules.setPausedInternet(true)
        com.familyshield.agent.enforcement.LockState.set(context, LockActivity.MODE_PAUSED_INTERNET)
        val webFilterSetUp = com.familyshield.agent.vpn.VpnState.isEnabled(context) &&
            com.familyshield.agent.vpn.FilterVpnService.isPrepared(context)
        if (webFilterSetUp) {
            runCatching { com.familyshield.agent.vpn.FilterVpnService.start(context, com.familyshield.agent.vpn.FilterVpnService.MODE_SINKHOLE_ALL) }
        }
        context.startActivity(
            Intent(context, LockActivity::class.java)
                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                .putExtra(LockActivity.EXTRA_MODE, LockActivity.MODE_PAUSED_INTERNET),
        )
        return EnforceabilityPolicy.pauseInternetOutcome(webFilterSetUp)
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

        /** The ADR-0031 notice's notification; [ResetCodeActivity] cancels it when the notice ends. */
        internal const val RESET_CODE_NOTIFICATION_ID = 43
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
         * when [raw] is missing, not a number, or not finite (`NaN`/`Infinity` parse as doubles but
         * are not a duration the parent asked for).
         */
        internal fun parseMinutes(raw: String?): Int? =
            raw?.toDoubleOrNull()?.takeIf { it.isFinite() }?.toInt()?.coerceIn(MIN_MINUTES, MAX_MINUTES)

        /**
         * Issue #231 review: a type this agent does not implement is acked `failed` with
         * [CommandAckPolicy.REASON_UNSUPPORTED_COMMAND], so the parent can say "update OSRA on your
         * child's phone" instead of the row staying `delivered` forever.
         */
        internal fun unknownTypeOutcome(): CommandOutcome =
            CommandOutcome.Refused(CommandAckPolicy.REASON_UNSUPPORTED_COMMAND)

        /**
         * Issue #231 review: an unparseable `bonus_time`/`wind_down` payload is acked `failed` with
         * [CommandAckPolicy.REASON_INVALID_PAYLOAD]; nothing ran, and silence left the row `delivered`.
         */
        internal fun invalidMinutesOutcome(): CommandOutcome =
            CommandOutcome.Refused(CommandAckPolicy.REASON_INVALID_PAYLOAD)
    }
}
