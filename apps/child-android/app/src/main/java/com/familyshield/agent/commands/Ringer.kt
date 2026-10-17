package com.familyshield.agent.commands

import android.content.Context
import android.content.Intent
import android.media.AudioAttributes
import android.media.AudioManager
import android.media.MediaPlayer
import android.media.RingtoneManager
import android.os.PowerManager
import android.util.Log
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch

/**
 * Plan 1.7 — the ring itself. Forces the alarm stream to its maximum (restored afterwards), plays the
 * default alarm on `USAGE_ALARM` (which Do-Not-Disturb lets through), holds a wake lock, turns the
 * screen on with [RingActivity] and keeps ringing until a [RingPolicy]-approved stop: the parent's
 * PIN on the ring screen, a parent command, or the cap. Process-wide singleton: one ring at a time.
 */
object Ringer {
    private const val TAG = "Ringer"
    private val lock = Any()
    private var player: MediaPlayer? = null
    private var wakeLock: PowerManager.WakeLock? = null
    private var previousVolume: Int = -1
    private var ringLevel: Int = -1
    private var capJob: Job? = null
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)

    @Volatile var isRinging: Boolean = false
        private set

    fun start(context: Context) {
        val app = context.applicationContext
        synchronized(lock) {
            stopLocked(app)
            val audio = app.getSystemService(AudioManager::class.java)
            if (audio != null) {
                previousVolume = audio.getStreamVolume(AudioManager.STREAM_ALARM)
                ringLevel = RingPolicy.ringVolume(audio.getStreamMaxVolume(AudioManager.STREAM_ALARM))
                runCatching { audio.setStreamVolume(AudioManager.STREAM_ALARM, ringLevel, 0) }
                    .onFailure { Log.w(TAG, "alarm volume not raised: ${it.message}") } // DND "total silence" can refuse
            }
            val p = MediaPlayer()
            try {
                p.setAudioAttributes(
                    AudioAttributes.Builder()
                        .setUsage(AudioAttributes.USAGE_ALARM)
                        .setContentType(AudioAttributes.CONTENT_TYPE_SONIFICATION)
                        .build(),
                )
                p.setDataSource(app, RingtoneManager.getDefaultUri(RingtoneManager.TYPE_ALARM))
                p.isLooping = true
                p.prepare()
                p.start()
            } catch (e: Exception) {
                Log.w(TAG, "ring failed", e)
                p.release()
                return
            }
            player = p
            val pm = app.getSystemService(PowerManager::class.java)
            @Suppress("DEPRECATION")
            wakeLock = pm?.newWakeLock(
                PowerManager.SCREEN_BRIGHT_WAKE_LOCK or PowerManager.ACQUIRE_CAUSES_WAKEUP or PowerManager.ON_AFTER_RELEASE,
                "osra:ring",
            )?.also { it.acquire(RingPolicy.MAX_RING_MS) }
            isRinging = true
            capJob = scope.launch {
                delay(RingPolicy.MAX_RING_MS)
                stop(app, RingPolicy.StopSource.TIMEOUT)
            }
        }
        app.startActivity(
            Intent(app, RingActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP),
        )
    }

    /** Stops the ring if [source] is allowed to; returns whether it stopped. */
    fun stop(context: Context, source: RingPolicy.StopSource): Boolean {
        if (!RingPolicy.stopAllowed(source)) return false
        val app = context.applicationContext
        synchronized(lock) { stopLocked(app) }
        app.startActivity(
            Intent(app, RingActivity::class.java)
                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP)
                .putExtra(RingActivity.EXTRA_DISMISS, true),
        )
        return true
    }

    private fun stopLocked(app: Context) {
        capJob?.cancel(); capJob = null
        player?.let { runCatching { it.stop() }; it.release() }
        player = null
        wakeLock?.let { if (it.isHeld) runCatching { it.release() } }
        wakeLock = null
        if (previousVolume >= 0) {
            val audio = app.getSystemService(AudioManager::class.java)
            if (audio != null) {
                val current = audio.getStreamVolume(AudioManager.STREAM_ALARM)
                runCatching { audio.setStreamVolume(AudioManager.STREAM_ALARM, RingPolicy.restoreVolume(previousVolume, current, ringLevel), 0) }
            }
            previousVolume = -1
        }
        isRinging = false
    }
}
