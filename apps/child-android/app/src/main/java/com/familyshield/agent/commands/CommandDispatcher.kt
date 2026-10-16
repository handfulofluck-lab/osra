package com.familyshield.agent.commands

import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.admin.DevicePolicyManager
import android.content.Context
import android.content.Intent
import android.media.AudioAttributes
import android.media.MediaPlayer
import android.media.RingtoneManager
import android.util.Log
import androidx.core.app.NotificationCompat
import androidx.core.content.ContextCompat
import com.familyshield.agent.data.RuleRepository
import com.familyshield.agent.services.LocationService
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
) {
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)
    private val ringLock = Any()
    private var ringer: MediaPlayer? = null
    private var ringJob: Job? = null
    private var windDownJob: Job? = null

    /** Executes the command [type] with its string [data] payload; unknown types are ignored. */
    fun dispatch(type: String, data: Map<String, String>) {
        when (type) {
            "lock" -> lock()
            "unlock" -> unlock()
            // NOTE: pause/resume reuse the overlay mechanics with paused messaging —
            // a paused device shows the full-screen overlay until resumed.
            "pause" -> pause()
            "resume" -> unlock()
            "ring" -> ring()
            "sos_clear" -> sosClear()
            "rules_updated" -> scope.launch { rules.refresh() }
            "locate_now" -> locateNow()
            // Feature #11: pause the internet — block everything except alwaysAllowedApps and
            // keep the overlay up until resume_internet arrives.
            "pause_internet" -> pauseInternet()
            "resume_internet" -> resumeInternet()
            // Feature #10: grant N extra screen-time minutes for today only.
            "bonus_time" -> dispatchMinutes(data) { rules.addBonusMinutes(it) }
            // Feature #22: warn, then lock after N minutes.
            "wind_down" -> dispatchMinutes(data) { windDown(it) }
            else -> Unit // NOTE: unknown command types are ignored by design
        }
    }

    /**
     * Parses and validates the minutes payload: tolerates "30" and "30.0" (the poll worker
     * stringifies JSON numbers), clamps to 1..240, and returns null for anything unparseable
     * or out of range — invalid values are ignored with a log rather than applied.
     */
    private fun dispatchMinutes(data: Map<String, String>, action: (Int) -> Unit) {
        val raw = data["minutes"]
        val minutes = parseMinutes(raw)
        if (minutes == null) {
            Log.w(TAG, "ignoring command: invalid minutes payload '$raw' (expected 1..240)")
            return
        }
        action(minutes)
    }

    /** Locks the device immediately when device owner, otherwise shows the full-screen overlay. */
    private fun lock() {
        // ADR-0010: a real screen lock when admin/owner permits it; the overlay stays up either way
        // so the child sees the "locked by your parent" screen and cannot swipe back to their apps.
        deviceAdmin.lockNow()
        context.startActivity(
            Intent(context, LockActivity::class.java)
                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                .putExtra(LockActivity.EXTRA_MODE, LockActivity.MODE_LOCKED),
        )
    }

    /** Shows the paused overlay (never device-owner lockNow — pause must be resumable via "resume"). */
    private fun pause() {
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
        context.startActivity(
            Intent(context, LockActivity::class.java)
                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                .putExtra(LockActivity.EXTRA_MODE, LockActivity.MODE_UNLOCK),
        )
    }

    /**
     * Enables pause-the-internet (Feature #11): RuleRepository blocks every app except
     * alwaysAllowedApps and the overlay stays up until resume_internet.
     * NOTE: the production path additionally routes all traffic through a VpnService
     * sinkhole (vpn builder allowing only alwaysAllowedApps' traffic); the test build
     * enforces via the overlay plus app blocking in the accessibility monitor.
     */
    private fun pauseInternet() {
        rules.setPausedInternet(true)
        context.startActivity(
            Intent(context, LockActivity::class.java)
                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                .putExtra(LockActivity.EXTRA_MODE, LockActivity.MODE_PAUSED_INTERNET),
        )
    }

    /** Clears pause-the-internet and dismisses the paused-internet overlay (single-task onNewIntent). */
    private fun resumeInternet() {
        rules.setPausedInternet(false)
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
    private fun ring() {
        synchronized(ringLock) { stopRingerLocked() }
        val player = MediaPlayer()
        try {
            player.setAudioAttributes(
                AudioAttributes.Builder()
                    .setUsage(AudioAttributes.USAGE_ALARM)
                    .setContentType(AudioAttributes.CONTENT_TYPE_SONIFICATION)
                    .build(),
            )
            player.setDataSource(context, RingtoneManager.getDefaultUri(RingtoneManager.TYPE_ALARM))
            player.isLooping = true
            player.prepare()
            player.start()
        } catch (e: Exception) {
            player.release()
            return
        }
        synchronized(ringLock) { ringer = player }
        ringJob = scope.launch {
            delay(RING_DURATION_MS)
            synchronized(ringLock) { stopRingerLocked() }
        }
    }

    /** Stops any active ring and dismisses the SOS screen (parent-side sos_clear, Feature #14). */
    private fun sosClear() {
        ringJob?.cancel()
        synchronized(ringLock) { stopRingerLocked() }
        // NOTE: single-task SosActivity re-delivers via onNewIntent and finishes on EXTRA_DISMISS.
        context.startActivity(
            Intent(context, SosActivity::class.java)
                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                .putExtra(SosActivity.EXTRA_DISMISS, true),
        )
    }

    /** Asks LocationService for an immediate ping + flush. */
    private fun locateNow() {
        runCatching {
            // NOTE: must be startForegroundService — LocationService calls startForeground() in
            // onStartCommand, and a plain startService() from the background (FCM/worker context)
            // throws IllegalStateException on API 26+, silently killing locate_now.
            ContextCompat.startForegroundService(
                context,
                Intent(context, LocationService::class.java)
                    .setAction(LocationService.ACTION_PING_NOW),
            )
        }
    }

    private fun stopRingerLocked() {
        ringer?.let {
            runCatching { it.stop() }
            it.release()
        }
        ringer = null
    }

    companion object {
        private const val TAG = "CommandDispatcher"
        private const val RING_DURATION_MS = 60_000L
        private const val CHANNEL_COMMANDS = "commands"
        private const val WIND_DOWN_NOTIFICATION_ID = 42
        private const val MIN_MINUTES = 1
        private const val MAX_MINUTES = 240

        /**
         * Pure minutes parser for command payloads: returns the clamped value in 1..240, or null
         * when [raw] is missing or not a number.
         */
        internal fun parseMinutes(raw: String?): Int? =
            raw?.toDoubleOrNull()?.toInt()?.coerceIn(MIN_MINUTES, MAX_MINUTES)
    }
}
