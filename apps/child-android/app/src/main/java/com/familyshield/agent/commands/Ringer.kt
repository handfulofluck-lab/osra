package com.familyshield.agent.commands

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.media.AudioAttributes
import android.media.AudioFocusRequest
import android.media.AudioManager
import android.media.MediaPlayer
import android.media.RingtoneManager
import android.os.PowerManager
import android.util.Log
import androidx.core.content.ContextCompat
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

    /**
     * osra-security#42 (Ahmed): the ring must keep its configured floor for its whole life. Three things
     * were missing and this holds all three: an `AUDIOFOCUS_GAIN` hold so another app cannot duck the alarm,
     * a `VOLUME_CHANGED_ACTION` watch on `STREAM_ALARM` so the hardware keys cannot quietly lower it from
     * the lock screen or another app, and a count of the attempts so the parent can be told.
     */
    private var focusRequest: AudioFocusRequest? = null
    private var volumeWatch: BroadcastReceiver? = null
    private var watchedApp: Context? = null

    /** How many times the stream was pushed back up during the ring. Read by the ack/report path. */
    @Volatile var volumeRestorations: Int = 0
        private set

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
            volumeRestorations = 0
            holdFocus(app)
            watchVolume(app)
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
        releaseFocus(app)
        stopWatchingVolume()
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

    /** `AUDIOFOCUS_GAIN`, not transient or may-duck: another app must not be able to lower the ring. */
    private fun holdFocus(app: Context) {
        val audio = app.getSystemService(AudioManager::class.java) ?: return
        val attrs = AudioAttributes.Builder()
            .setUsage(AudioAttributes.USAGE_ALARM)
            .setContentType(AudioAttributes.CONTENT_TYPE_SONIFICATION)
            .build()
        val request = AudioFocusRequest.Builder(AudioManager.AUDIOFOCUS_GAIN)
            .setAudioAttributes(attrs)
            .build()
        runCatching { audio.requestAudioFocus(request) }
            .onFailure { Log.w(TAG, "audio focus not held: ${it.message}") }
        focusRequest = request
    }

    private fun releaseFocus(app: Context) {
        val request = focusRequest ?: return
        focusRequest = null
        app.getSystemService(AudioManager::class.java)?.let { runCatching { it.abandonAudioFocusRequest(request) } }
    }

    /**
     * Listens for the hardware volume keys on the alarm stream. `RingActivity` swallows the keys only while
     * its own window has focus; from the lock screen, the shade or another app they still land, which is how
     * the Flip4 ring got quieter with no PIN entered.
     */
    private fun watchVolume(app: Context) {
        stopWatchingVolume()
        val receiver = object : BroadcastReceiver() {
            override fun onReceive(context: Context?, intent: Intent?) {
                if (intent?.action != "android.media.VOLUME_CHANGED_ACTION") return
                val stream = intent.getIntExtra("android.media.EXTRA_VOLUME_STREAM_TYPE", -1)
                if (stream != AudioManager.STREAM_ALARM) return
                val audio = app.getSystemService(AudioManager::class.java) ?: return
                val floor = ringLevel
                val current = audio.getStreamVolume(AudioManager.STREAM_ALARM)
                if (RingPolicy.volumeVerdict(current, floor) == RingPolicy.VolumeVerdict.RESTORE) {
                    runCatching { audio.setStreamVolume(AudioManager.STREAM_ALARM, floor, 0) }
                    volumeRestorations += 1
                    Log.w(TAG, "alarm volume dropped to $current during the ring; raised back to $floor")
                }
            }
        }
        val filter = IntentFilter("android.media.VOLUME_CHANGED_ACTION")
        // Same shape as LockActivity/BlockActivity: targetSdk 35 requires the export flag, and this is a
        // system broadcast we only read.
        runCatching {
            ContextCompat.registerReceiver(app, receiver, filter, ContextCompat.RECEIVER_NOT_EXPORTED)
        }
            .onSuccess { volumeWatch = receiver; watchedApp = app }
            .onFailure { Log.w(TAG, "volume watch not registered: ${it.message}") }
    }

    private fun stopWatchingVolume() {
        val receiver = volumeWatch ?: return
        volumeWatch = null
        watchedApp?.let { ctx -> runCatching { ctx.unregisterReceiver(receiver) } }
        watchedApp = null
    }
}
