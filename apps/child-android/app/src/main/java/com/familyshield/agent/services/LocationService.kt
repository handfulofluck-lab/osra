package com.familyshield.agent.services

import android.Manifest
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Intent
import android.content.pm.PackageManager
import android.content.pm.ServiceInfo
import android.location.Location
import android.net.ConnectivityManager
import android.os.Build
import android.os.IBinder
import android.os.Looper
import android.util.Log
import androidx.core.app.NotificationCompat
import androidx.core.app.ServiceCompat
import androidx.core.content.ContextCompat
import com.familyshield.agent.data.AgentSettings
import com.familyshield.agent.data.db.FamilyShieldDatabase
import com.familyshield.agent.data.db.PendingPingEntity
import com.familyshield.agent.commands.CommandDispatcher
import com.familyshield.agent.network.ApiService
import com.familyshield.agent.network.dto.AlertDto
import com.familyshield.agent.network.dto.LocationPingBatchDto
import com.familyshield.agent.network.dto.LocationPingDto
import com.familyshield.agent.receivers.AccessibilityOffReceiver
import com.familyshield.agent.receivers.AlertThrottlePolicy
import com.familyshield.agent.receivers.VpnDetectPolicy
import com.familyshield.agent.telemetry.UsageReporter
import com.google.android.gms.location.LocationCallback
import com.google.android.gms.location.LocationRequest
import com.google.android.gms.location.LocationResult
import com.google.android.gms.location.LocationServices
import com.google.android.gms.location.Priority
import dagger.hilt.android.AndroidEntryPoint
import java.time.Instant
import javax.inject.Inject
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.delay
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock

/**
 * Foreground location service: FusedLocationProviderClient with PRIORITY_BALANCED_POWER_ACCURACY
 * and an adaptive interval (30 s while moving > 5 m/s, 5 min stationary). Pings are batched in
 * memory, flushed to POST /v1/location/ping every 60 s; on failure they are persisted in Room and
 * re-uploaded by PendingPingWorker when the network is back. The same 60 s loop posts the
 * Feature #29 live-activity snapshot (foreground app + today's total minutes) and runs the
 * Feature #19/#20 tamper checks (accessibility-disabled, VPN routing).
 */
@AndroidEntryPoint
class LocationService : Service() {

    @Inject lateinit var api: ApiService
    @Inject lateinit var settings: AgentSettings
    @Inject lateinit var db: FamilyShieldDatabase
    @Inject lateinit var dispatcher: CommandDispatcher
    @Inject lateinit var usage: UsageReporter

    private val serviceScope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    private lateinit var fused: com.google.android.gms.location.FusedLocationProviderClient
    private val pingLock = Any()
    private val memoryPings = ArrayList<LocationPingDto>()
    private val accessibilityOffReceiver = AccessibilityOffReceiver()

    @Volatile private var intervalMs = STATIONARY_INTERVAL_MS
    @Volatile private var flushLoopStarted = false
    @Volatile private var commandLoopStarted = false

    private val callback = object : LocationCallback() {
        override fun onLocationResult(result: LocationResult) {
            for (location in result.locations) onLocation(location)
        }
    }

    override fun onCreate() {
        super.onCreate()
        fused = LocationServices.getFusedLocationProviderClient(this)
        createNotificationChannel()
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val fgsStarted = startForegroundCompat()
        if (!fgsStarted) {
            stopSelf()
            return START_NOT_STICKY
        }
        startUpdates(STATIONARY_INTERVAL_MS)
        if (!flushLoopStarted) {
            flushLoopStarted = true
            serviceScope.launch {
                while (isActive) {
                    delay(FLUSH_INTERVAL_MS)
                    runCatching { flushPings() }
                    // Feature #29: 60 s live-activity heartbeat (foreground app + total minutes).
                    runCatching { usage.postLiveActivity() }
                    // Features #19/#20: 60 s tamper checks (accessibility disabled, VPN routing).
                    runCatching { tamperChecksOnce() }
                }
            }
        }
        if (!commandLoopStarted) {
            commandLoopStarted = true
            // Foreground-service poll loop: WorkManager periodic work is OS-clamped to
            // 15 min, so device commands (rules_updated, ring, lock...) are polled here
            // every COMMAND_POLL_INTERVAL_MS while the service runs.
            serviceScope.launch {
                while (isActive) {
                    delay(COMMAND_POLL_INTERVAL_MS)
                    pollCommandsOnce()
                }
            }
        }
        if (intent?.action == ACTION_PING_NOW) {
            serviceScope.launch {
                runCatching {
                    fused.lastLocation.addOnSuccessListener { location ->
                        location?.let { onLocation(it) }
                    }
                }
                runCatching { flushPings() }
            }
        }
        return START_STICKY
    }

    override fun onDestroy() {
        fused.removeLocationUpdates(callback)
        serviceScope.cancel()
        super.onDestroy()
    }

    override fun onBind(intent: Intent?): IBinder? = null

    /** Queues one ping and adapts the update interval to the current speed. */
    private fun onLocation(location: Location) {
        val ping = LocationPingDto(
            lat = location.latitude,
            lng = location.longitude,
            accuracyM = location.accuracy,
            timestamp = Instant.ofEpochMilli(location.time).toString(),
        )
        synchronized(pingLock) { memoryPings.add(ping) }
        val moving = location.hasSpeed() && location.speed > MOVING_SPEED_MS
        val desired = if (moving) MOVING_INTERVAL_MS else STATIONARY_INTERVAL_MS
        if (desired != intervalMs) startUpdates(desired)
    }

    /** (Re)starts location updates with the given [interval]; no-op without location permission. */
    private fun startUpdates(interval: Long) {
        intervalMs = interval
        val request = LocationRequest.create()
            .setPriority(Priority.PRIORITY_BALANCED_POWER_ACCURACY)
            .setInterval(interval)
            .setFastestInterval(FASTEST_INTERVAL_MS)
        fused.removeLocationUpdates(callback)
        val granted = ContextCompat.checkSelfPermission(this, Manifest.permission.ACCESS_FINE_LOCATION) ==
            PackageManager.PERMISSION_GRANTED ||
            ContextCompat.checkSelfPermission(this, Manifest.permission.ACCESS_COARSE_LOCATION) ==
            PackageManager.PERMISSION_GRANTED
        if (!granted) return
        try {
            fused.requestLocationUpdates(request, callback, Looper.getMainLooper())
        } catch (e: SecurityException) {
            // Permission revoked between check and request; the next boot/command retries.
        }
    }

    /** Uploads memory + Room pings; on failure persists the memory batch into Room. */
    suspend fun flushPings() {
        FLUSH_MUTEX.withLock {
            val mem = synchronized(pingLock) { ArrayList(memoryPings) }
            val stored = db.pendingPingDao().all()
            val all = mem + stored.map {
                LocationPingDto(lat = it.lat, lng = it.lng, accuracyM = it.accuracyM, timestamp = Instant.ofEpochMilli(it.timestamp).toString())
            }
            if (all.isEmpty()) return@withLock
            try {
                api.postLocationPings(LocationPingBatchDto(all))
                synchronized(pingLock) { memoryPings.removeAll(mem) }
                db.pendingPingDao().clear()
            } catch (e: CancellationException) {
                throw e // NOTE: never swallow coroutine cancellation
            } catch (e: Exception) {
                db.pendingPingDao().insertAll(mem.map {
                    PendingPingEntity(lat = it.lat, lng = it.lng, accuracyM = it.accuracyM, timestamp = Instant.parse(it.timestamp).toEpochMilli())
                })
                synchronized(pingLock) { memoryPings.removeAll(mem) }
            }
        }
    }

    private fun hasLocationPermission(): Boolean {
        val hasFine = ContextCompat.checkSelfPermission(this, Manifest.permission.ACCESS_FINE_LOCATION) == PackageManager.PERMISSION_GRANTED
        val hasCoarse = ContextCompat.checkSelfPermission(this, Manifest.permission.ACCESS_COARSE_LOCATION) == PackageManager.PERMISSION_GRANTED
        return hasFine || hasCoarse
    }

    private fun startForegroundCompat(): Boolean {
        if (!hasLocationPermission()) {
            Log.w(TAG, "Cannot start location foreground service: location permission not granted")
            return false
        }
        val notification = buildNotification()
        return try {
            if (Build.VERSION.SDK_INT >= 29) {
                ServiceCompat.startForeground(this, NOTIFICATION_ID, notification, ServiceInfo.FOREGROUND_SERVICE_TYPE_LOCATION)
            } else {
                startForeground(NOTIFICATION_ID, notification)
            }
            true
        } catch (e: SecurityException) {
            Log.e(TAG, "SecurityException starting location foreground service", e)
            false
        }
    }

    private fun buildNotification(): Notification {
        val launchIntent = packageManager.getLaunchIntentForPackage(packageName)
        val pendingIntent = launchIntent?.let {
            PendingIntent.getActivity(this, 0, it, PendingIntent.FLAG_IMMUTABLE)
        }
        return NotificationCompat.Builder(this, CHANNEL_ID)
            .setSmallIcon(android.R.drawable.ic_menu_mylocation)
            .setContentTitle("OSRA")
            .setContentText("Location sharing is active")
            .setContentIntent(pendingIntent)
            .setOngoing(true)
            .setCategory(NotificationCompat.CATEGORY_SERVICE)
            .setPriority(NotificationCompat.PRIORITY_HIGH)
            .build()
    }

    private fun createNotificationChannel() {
        val channel = NotificationChannel(CHANNEL_ID, "Location", NotificationManager.IMPORTANCE_HIGH)
        getSystemService(NotificationManager::class.java).createNotificationChannel(channel)
    }

    /** Drain pending device commands and dispatch them; errors are logged, never thrown. */
    private suspend fun pollCommandsOnce() {
        val deviceId = settings.deviceId() ?: return
        runCatching {
            val commands = api.getCommands(deviceId)
            for (command in commands) {
                runCatching {
                    val data = (command.payload ?: emptyMap()).mapValues { it.value.toString() }
                    dispatcher.dispatch(command.type, data)
                }.onFailure { Log.w(TAG, "command failed: ${command.type}", it) }
            }
        }.onFailure { Log.w(TAG, "command poll failed", it) }
    }

    /**
     * Feature #19 accessibility-off check plus Feature #20 VPN check, both throttled to one alert
     * per type per hour (DataStore timestamps, see AlertThrottlePolicy). No-op while unpaired;
     * errors are logged, never thrown.
     */
    private suspend fun tamperChecksOnce() {
        if (!settings.isPaired()) return
        val nowMs = System.currentTimeMillis()
        runCatching { accessibilityOffReceiver.checkOnce(this, api, settings, nowMs) }
            .onFailure { Log.w(TAG, "accessibility tamper check failed", it) }
        runCatching { vpnCheckOnce(nowMs) }
            .onFailure { Log.w(TAG, "vpn check failed", it) }
    }

    /** Feature #20: posts a vpn_detected warning when the active network routes through a VPN. */
    private suspend fun vpnCheckOnce(nowMs: Long) {
        val cm = getSystemService(ConnectivityManager::class.java) ?: return
        val caps = cm.getNetworkCapabilities(cm.activeNetwork)
        if (!VpnDetectPolicy.hasVpnTransport(caps)) return
        if (!AlertThrottlePolicy.shouldAlert(settings.tamperAlertTimestamp(VpnDetectPolicy.TYPE), nowMs)) return
        val childId = settings.childId() ?: return
        runCatching {
            api.postInternalAlert(
                AlertDto(
                    childId = childId,
                    deviceId = settings.deviceId(),
                    severity = "warning",
                    category = "vpn_detected",
                    title = "VPN active",
                    body = "A VPN is routing this device's traffic around the filter",
                    metadata = emptyMap(),
                ),
            )
        }.onSuccess {
            // NOTE: timestamp recorded only on success so a failed POST does not throttle retries.
            settings.recordTamperAlert(VpnDetectPolicy.TYPE, nowMs)
        }
    }

    companion object {
        /** Action that triggers an immediate single ping + flush (locate_now command). */
        const val ACTION_PING_NOW: String = "com.familyshield.agent.action.PING_NOW"

        /**
         * Serializes ping flushes across LocationService and PendingPingWorker (same process):
         * without it, concurrent flushes could upload duplicates or delete freshly persisted
         * pings from Room before they were sent.
         */
        internal val FLUSH_MUTEX: Mutex = Mutex()

        private const val CHANNEL_ID = "location"
        private const val TAG = "LocationService"
        private const val NOTIFICATION_ID = 1001
        private const val STATIONARY_INTERVAL_MS = 5L * 60L * 1000L
        private const val MOVING_INTERVAL_MS = 30L * 1000L
        private const val FASTEST_INTERVAL_MS = 30L * 1000L
        private const val FLUSH_INTERVAL_MS = 60L * 1000L
        private const val COMMAND_POLL_INTERVAL_MS = 60L * 1000L
        private const val MOVING_SPEED_MS = 5f
    }
}
