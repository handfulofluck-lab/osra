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
import android.os.PowerManager
import android.os.SystemClock
import android.util.Log
import androidx.core.app.NotificationCompat
import androidx.core.app.ServiceCompat
import androidx.core.content.ContextCompat
import com.familyshield.agent.data.AgentSettings
import com.familyshield.agent.data.db.FamilyShieldDatabase
import com.familyshield.agent.data.db.PendingPingEntity
import com.familyshield.agent.commands.CommandDispatcher
import com.familyshield.agent.commands.CommandPoller
import com.familyshield.agent.push.PushTokenUploadPolicy
import com.familyshield.agent.commands.LocateFix
import com.familyshield.agent.data.ConsentPolicy
import com.familyshield.agent.data.ConsentState
import com.familyshield.agent.network.ApiService
import com.familyshield.agent.network.dto.AlertDto
import com.familyshield.agent.network.dto.LocationPingBatchDto
import com.familyshield.agent.network.dto.LocationPingDto
import com.familyshield.agent.receivers.AccessibilityOffReceiver
import com.familyshield.agent.receivers.AlertThrottlePolicy
import com.familyshield.agent.receivers.VpnDetectPolicy
import com.familyshield.agent.security.PermissionObservationPolicy
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
import retrofit2.HttpException

/**
 * Foreground location service: FusedLocationProviderClient with PRIORITY_BALANCED_POWER_ACCURACY
 * and an adaptive interval (30 s while moving > 5 m/s, 5 min stationary). Pings are batched in
 * memory and flushed to POST /v1/location/ping from a 60 s loop; on failure they are persisted in
 * Room and re-uploaded by PendingPingWorker when the network is back. The same 60 s loop posts the
 * Feature #29 live-activity snapshot (foreground app + today's total minutes) and runs the
 * Feature #19/#20 tamper checks (accessibility-disabled, VPN routing).
 *
 * Roadmap 5.8 (#353): a foreground service keeps its network in Doze, so these loops are what an
 * idle phone costs the server. [IdleCadence] decides when each one actually sends: the commands
 * poll follows the server's `X-Poll-After` (at most 60 s apart while the screen is on), live
 * activity goes up only while the screen is on, and a stationary batch waits until its oldest ping
 * is 10 minutes old.
 */
@AndroidEntryPoint
class LocationService : Service() {

    @Inject lateinit var api: ApiService
    @Inject lateinit var settings: AgentSettings
    @Inject lateinit var db: FamilyShieldDatabase
    @Inject lateinit var dispatcher: CommandDispatcher
    @Inject lateinit var consentState: ConsentState
    // #383: the service's own poll is the one that runs while the app is foregrounded, so the token
    // step has to happen here too — the worker skips its poll while this service runs.
    @Inject lateinit var commandPoller: CommandPoller
    @Inject lateinit var usage: UsageReporter

    private val serviceScope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    private lateinit var fused: com.google.android.gms.location.FusedLocationProviderClient
    private val pingLock = Any()
    private val memoryPings = ArrayList<LocationPingDto>()
    private val accessibilityOffReceiver = AccessibilityOffReceiver()

    @Volatile private var intervalMs = STATIONARY_INTERVAL_MS
    @Volatile private var flushLoopStarted = false
    @Volatile private var commandLoopStarted = false

    /** #353: the server's poll interval from the last answer; [IdleCadence.DEFAULT_POLL_MS] until then. */
    @Volatile private var serverPollMs = IdleCadence.DEFAULT_POLL_MS

    /** #353: when the oldest ping now in [memoryPings] was buffered (elapsedRealtime); guarded by [pingLock]. */
    private var bufferedSinceMs: Long? = null

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
            isServiceRunning = false
            stopSelf()
            return START_NOT_STICKY
        }
        isServiceRunning = true
        startUpdates(STATIONARY_INTERVAL_MS)
        if (!flushLoopStarted) {
            flushLoopStarted = true
            serviceScope.launch {
                var wasInteractive = isInteractive()
                while (isActive) {
                    delay(FLUSH_INTERVAL_MS)
                    val interactive = isInteractive()
                    // #353: a stationary batch waits until its oldest ping is 10 minutes old.
                    runCatching { if (shouldFlushNow()) flushPings() }
                    // Feature #29: live-activity heartbeat (foreground app + total minutes), only while
                    // the screen is on, plus one "idle" snapshot on the tick after it turns off (#353).
                    if (IdleCadence.shouldPostLiveActivity(interactive, wasInteractive)) {
                        runCatching { usage.postLiveActivity(screenOn = interactive) }
                    }
                    wasInteractive = interactive
                    // Features #19/#20: 60 s tamper checks (accessibility disabled, VPN routing).
                    runCatching { tamperChecksOnce() }
                }
            }
        }
        if (!commandLoopStarted) {
            commandLoopStarted = true
            // Foreground-service poll loop: WorkManager periodic work is OS-clamped to
            // 15 min, so device commands (rules_updated, ring, lock...) are polled here while the
            // service runs. #353: the interval is the server's X-Poll-After (600 s when it can wake
            // this phone by push, else 60 s), capped at 60 s while the screen is on; the loop
            // ticks every 15 s so turning the screen on brings the next poll forward.
            serviceScope.launch {
                var lastPollAtMs: Long? = null
                while (isActive) {
                    delay(IdleCadence.POLL_TICK_MS)
                    val now = SystemClock.elapsedRealtime()
                    if (IdleCadence.pollDue(lastPollAtMs, now, serverPollMs, isInteractive())) {
                        lastPollAtMs = now
                        pollCommandsOnce()
                    }
                }
            }
        }
        if (intent?.action == ACTION_PING_NOW) {
            // Issue #231: the row id travels with the intent so this service can ack `locate_now`
            // once it knows whether a fix exists — the dispatcher deliberately does not.
            val commandId = intent.getStringExtra(EXTRA_COMMAND_ID)
            serviceScope.launch { locateNowOnce(commandId) }
        }
        return START_STICKY
    }

    override fun onDestroy() {
        isServiceRunning = false
        fused.removeLocationUpdates(callback)
        serviceScope.cancel()
        super.onDestroy()
    }

    override fun onBind(intent: Intent?): IBinder? = null

    /**
     * Plan 1.7: `locate_now` asks the fused provider for a **fresh high-accuracy fix** and waits up to
     * [com.familyshield.agent.commands.LocatePolicy.FRESH_FIX_TIMEOUT_MS] for it; only if that fails is
     * the last known fix used, and only while it is recent ([LocatePolicy.MAX_CACHED_AGE_MS]). Either way
     * the ping is flushed at once so the parent's map moves within the timeout, not at the next batch.
     *
     * Issue #231: [commandId] is the durable row from the poll (null on the FCM path, which has no
     * row). The ack is sent after the flush attempt and says whether a fix was obtained — a started
     * service is not an effect the parent can see, so the dispatcher defers this ack to here.
     */
    private suspend fun locateNowOnce(commandId: String?) {
        val fresh: Location? = try {
            kotlinx.coroutines.withTimeoutOrNull(com.familyshield.agent.commands.LocatePolicy.FRESH_FIX_TIMEOUT_MS) {
                kotlinx.coroutines.suspendCancellableCoroutine { cont ->
                    val cts = com.google.android.gms.tasks.CancellationTokenSource()
                    cont.invokeOnCancellation { cts.cancel() }
                    try {
                        fused.getCurrentLocation(Priority.PRIORITY_HIGH_ACCURACY, cts.token)
                            .addOnSuccessListener { if (cont.isActive) cont.resume(it) {} }
                            .addOnFailureListener { if (cont.isActive) cont.resume(null) {} }
                    } catch (e: SecurityException) {
                        if (cont.isActive) cont.resume(null) {}
                    }
                }
            }
        } catch (e: Exception) {
            null
        }
        val cached: Location? = if (fresh == null) {
            try {
                kotlinx.coroutines.suspendCancellableCoroutine { cont ->
                    try {
                        fused.lastLocation
                            .addOnSuccessListener { if (cont.isActive) cont.resume(it) {} }
                            .addOnFailureListener { if (cont.isActive) cont.resume(null) {} }
                    } catch (e: SecurityException) { if (cont.isActive) cont.resume(null) {} }
                }
            } catch (e: Exception) { null }
        } else null
        val now = System.currentTimeMillis()
        val fix: LocateFix? = when (com.familyshield.agent.commands.LocatePolicy.choose(fresh != null, cached?.time, now)) {
            com.familyshield.agent.commands.LocatePolicy.Choice.FRESH -> {
                onLocation(fresh!!)
                LocateFix.FRESH
            }
            com.familyshield.agent.commands.LocatePolicy.Choice.CACHED -> {
                onLocation(cached!!)
                LocateFix.CACHED
            }
            com.familyshield.agent.commands.LocatePolicy.Choice.NONE -> {
                Log.w(TAG, "locate_now: no fix within the timeout and nothing recent cached")
                null
            }
        }
        // Issue #231 review: the ack may only claim a point the server has. An upload failure keeps
        // the ping buffered, so no ack goes out and the row is re-offered at 120 s.
        val uploaded = runCatching { flushPings() }.getOrDefault(false)
        if (fix != null && !uploaded) {
            Log.w(TAG, "locate_now: fix obtained but not uploaded; no ack, the command is re-offered at 120 s")
        }
        dispatcher.ackLocateNow(commandId, fix, uploaded)
    }

    /** Queues one ping and adapts the update interval to the current speed. */
    private fun onLocation(location: Location) {
        val ping = LocationPingDto(
            lat = location.latitude,
            lng = location.longitude,
            accuracyM = location.accuracy,
            timestamp = Instant.ofEpochMilli(location.time).toString(),
        )
        synchronized(pingLock) {
            if (memoryPings.isEmpty()) bufferedSinceMs = SystemClock.elapsedRealtime()
            memoryPings.add(ping)
        }
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

    /**
     * Uploads memory + Room pings; on failure persists the memory batch into Room.
     *
     * Issue #231 review: returns **true only when the POST succeeded** — i.e. the batch that holds
     * the caller's point is on the server. It returns false when consent is paused (the pings are
     * discarded, never uploaded), when there was nothing to upload, and when the POST threw (the
     * batch is buffered in Room). `locateNowOnce` uses this to withhold the `ok` ack; the periodic
     * flush ignores it, because Room is the durable retry for that path.
     */
    suspend fun flushPings(): Boolean = FLUSH_MUTEX.withLock {
        if (consentState.isPaused()) {
            // ADR-0008 §3: withdrawal stops collection — discard, do not buffer for later upload.
            synchronized(pingLock) { memoryPings.clear(); bufferedSinceMs = null }
            runCatching { db.pendingPingDao().clear() }
            return@withLock false
        }
        val mem = synchronized(pingLock) { ArrayList(memoryPings) }
        val stored = db.pendingPingDao().all()
        val all = mem + stored.map {
            LocationPingDto(lat = it.lat, lng = it.lng, accuracyM = it.accuracyM, timestamp = Instant.ofEpochMilli(it.timestamp).toString())
        }
        if (all.isEmpty()) return@withLock false
        try {
            api.postLocationPings(LocationPingBatchDto(all))
            dropBuffered(mem)
            db.pendingPingDao().clear()
            true
        } catch (e: CancellationException) {
            throw e // NOTE: never swallow coroutine cancellation
        } catch (e: Exception) {
            db.pendingPingDao().insertAll(mem.map {
                PendingPingEntity(lat = it.lat, lng = it.lng, accuracyM = it.accuracyM, timestamp = Instant.parse(it.timestamp).toEpochMilli())
            })
            dropBuffered(mem)
            false
        }
    }

    /**
     * Removes an uploaded (or Room-persisted) batch from memory. A ping that arrived during the
     * upload stays, and its batch age restarts now, which can only delay that one ping's flush by
     * the length of the upload.
     */
    private fun dropBuffered(sent: List<LocationPingDto>) {
        synchronized(pingLock) {
            memoryPings.removeAll(sent)
            bufferedSinceMs = if (memoryPings.isEmpty()) null else SystemClock.elapsedRealtime()
        }
    }

    /** #353: the flush rule from [IdleCadence.shouldFlushPings], fed with this service's state. */
    private suspend fun shouldFlushNow(): Boolean {
        val since = synchronized(pingLock) { bufferedSinceMs }
        val stored = runCatching { db.pendingPingDao().all().isNotEmpty() }.getOrDefault(false)
        return IdleCadence.shouldFlushPings(
            moving = intervalMs == MOVING_INTERVAL_MS,
            paused = consentState.isPaused(),
            bufferedSinceMs = since,
            hasStoredBatch = stored,
            nowMs = SystemClock.elapsedRealtime(),
        )
    }

    /** #353: screen on, so the child may be using the phone. Unknown counts as on (the old cadence). */
    private fun isInteractive(): Boolean = getSystemService(PowerManager::class.java)?.isInteractive ?: true

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
            val response = api.getCommandsWithCadence(deviceId)
            // Issue #465: this poll is the one a paired phone actually runs, so the revoked answer has to
            // reach the shared path or the unlink never fires.
            if (commandPoller.onPollAnswer(response)) return@runCatching
            if (!response.isSuccessful) throw HttpException(response) // keeps the 428 consent path
            // #383: a token the server cleared is re-sent from here, because this poll is the one that
            // runs on a paired phone (the worker skips its own while this service is up).
            commandPoller.syncPushToken(deviceId, response.headers()[PushTokenUploadPolicy.PUSH_TOKEN_HEADER])
            // #353: the server says how long to wait. An older server sends nothing: 60 s, as before.
            serverPollMs = IdleCadence.pollAfterMs(response.headers()[IdleCadence.POLL_AFTER_HEADER])
            consentState.onPollStatus(200)
            for (command in response.body().orEmpty()) {
                runCatching {
                    val data = (command.payload ?: emptyMap()).mapValues { it.value.toString() }
                    // Issue #132: the row id lets a refused locate_now report a `failed` ack.
                    dispatcher.dispatch(command.type, data, command.id)
                }.onFailure { Log.w(TAG, "command failed: ${command.type}", it) }
            }
        }.onFailure {
            serverPollMs = IdleCadence.DEFAULT_POLL_MS // no answer to go by: back to 60 s
            consentState.onPollFailure(it) // ADR-0008 §3: 428 = consent withdrawn, pause collection
            // Issue #260: a 428 is the *expected* answer while consent is withdrawn, and ConsentState
            // already logs the transition once. Logging the whole HttpException stack every 60 seconds
            // buried the lines that mattered in a phone log that was read during a real investigation.
            if (ConsentPolicy.httpStatusOf(it) == 428) return@onFailure
            Log.w(TAG, "command poll failed", it)
        }
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
        runCatching { deviceAdminCheckOnce() }
            .onFailure { Log.w(TAG, "device admin check failed", it) }
        runCatching { privateDnsCheckOnce(nowMs) }
            .onFailure { Log.w(TAG, "private dns check failed", it) }
        runCatching { overlayCheckOnce(nowMs) }
            .onFailure { Log.w(TAG, "overlay check failed", it) }
    }

    /**
     * Plan 1.9 (bypass #7): a Private DNS provider set while the web filter is on bypasses the DNS
     * sinkhole silently (the guard covers the Settings dialog; `adb` or a different launcher does not
     * go through it). Alert once per throttle window, like the accessibility check.
     */
    private suspend fun privateDnsCheckOnce(nowMs: Long) {
        if (!com.familyshield.agent.vpn.VpnState.isEnabled(this)) return
        val mode = android.provider.Settings.Global.getString(contentResolver, "private_dns_mode")
        if (com.familyshield.agent.setup.OnboardingPolicy.privateDnsOk(mode)) return
        postTamperOnce(nowMs, TYPE_PRIVATE_DNS, "Web filter bypassed", "Private DNS was set to a provider on this device, which routes around OSRA's web filter")
    }

    /**
     * Plan 1.9 (bypass #5): the overlay permission revoked means the lock/pause screens cannot be
     * shown. Issue #225: like the accessibility check, this is an edge over a persisted observation
     * — a fresh install that never granted the permission is not tamper, so the first observation
     * is silent. The new observation is recorded even when no alert is raised; revoked is recorded
     * only after a successful POST so a failed call retries.
     */
    private suspend fun overlayCheckOnce(nowMs: Long) {
        val grantedNow = android.provider.Settings.canDrawOverlays(this)
        if (!PermissionObservationPolicy.shouldAlertOnObservation(settings.overlayWasGranted(), grantedNow)) {
            settings.recordOverlayGranted(grantedNow)
            return
        }
        // The edge is real. If the type is throttled, record it revoked: this event was already
        // reported inside the window, and leaving it granted would repeat the alert when it expires.
        if (!AlertThrottlePolicy.shouldAlert(settings.tamperAlertTimestamp(TYPE_OVERLAY_REVOKED), nowMs)) {
            settings.recordOverlayGranted(false)
            return
        }
        val childId = settings.childId() ?: return
        runCatching {
            api.postInternalAlert(
                AlertDto(
                    childId = childId,
                    deviceId = settings.deviceId(),
                    severity = "critical",
                    category = "tamper",
                    title = "Lock screen permission removed",
                    body = "\"Display over other apps\" was turned off for OSRA; the lock and pause screens cannot be shown until it is re-enabled",
                    metadata = mapOf("type" to TYPE_OVERLAY_REVOKED),
                ),
            )
        }.onSuccess {
            settings.recordOverlayGranted(false)
            settings.recordTamperAlert(TYPE_OVERLAY_REVOKED, nowMs)
        }
    }

    private suspend fun postTamperOnce(nowMs: Long, type: String, title: String, body: String) {
        if (!AlertThrottlePolicy.shouldAlert(settings.tamperAlertTimestamp(type), nowMs)) return
        val childId = settings.childId() ?: return
        runCatching {
            api.postInternalAlert(
                AlertDto(childId = childId, deviceId = settings.deviceId(), severity = "critical", category = "tamper", title = title, body = body, metadata = mapOf("type" to type)),
            )
        }.onSuccess { settings.recordTamperAlert(type, nowMs) }
    }

    /**
     * ADR-0010 §4: if the admin receiver recorded a removal that has not reached the parent yet
     * (the expedited worker is the fast path; this is the backstop), or the protection tier dropped
     * to NONE since the last loop, post one tamper alert.
     */
    private fun deviceAdminCheckOnce() {
        val entry = dagger.hilt.android.EntryPointAccessors.fromApplication(applicationContext, com.familyshield.agent.di.WorkerEntryPoint::class.java)
        val admin = entry.deviceAdminManager()
        val tier = admin.tier()
        val previous = com.familyshield.agent.security.TamperState.lastTier(this)
            ?.let { runCatching { com.familyshield.agent.security.ProtectionTier.valueOf(it) }.getOrNull() }
        com.familyshield.agent.security.TamperState.setLastTier(this, tier.name)
        val dropped = previous != null && com.familyshield.agent.security.TamperPolicy.shouldAlertOnTier(previous, tier)
        if (com.familyshield.agent.security.TamperState.isAdminDisabledPending(this) || dropped) {
            // Issue #225: reuse the timestamp onDisabled recorded so this enqueue and the receiver's
            // expedited work carry the same dedupe key; only a drop with no recorded event stamps now.
            val eventAtMs = com.familyshield.agent.security.TamperState.adminDisabledAtMs(this)
                .takeIf { it > 0L }
                ?: System.currentTimeMillis().also {
                    com.familyshield.agent.security.TamperState.setAdminDisabledAt(this, it)
                }
            com.familyshield.agent.security.TamperAlertWorker.enqueue(
                this,
                com.familyshield.agent.security.TamperAlertWorker.TYPE_ADMIN_REMOVED,
                eventAtMs = eventAtMs,
            )
        }
    }

    /** Feature #20: posts a vpn_detected warning when the active network routes through a VPN. */
    private suspend fun vpnCheckOnce(nowMs: Long) {
        val cm = getSystemService(ConnectivityManager::class.java) ?: return
        val caps = cm.getNetworkCapabilities(cm.activeNetwork)
        if (!VpnDetectPolicy.hasVpnTransport(caps)) return
        // Plan 1.4: Android runs one VPN at a time — while our own sinkhole holds the slot, the transport is ours.
        if (com.familyshield.agent.vpn.VpnState.isEstablished(this)) return
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
        const val TYPE_PRIVATE_DNS = "private_dns_bypass"
        const val TYPE_OVERLAY_REVOKED = "overlay_revoked"

        /** Action that triggers an immediate single ping + flush (locate_now command). */
        const val ACTION_PING_NOW: String = "com.familyshield.agent.action.PING_NOW"

        /** Issue #231: durable `DeviceCommand.id` carried from the dispatcher for the deferred ack. */
        const val EXTRA_COMMAND_ID: String = "com.familyshield.agent.extra.COMMAND_ID"

        /** True while LocationService is active in foreground with updates running. */
        @Volatile
        var isServiceRunning: Boolean = false
            internal set

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
        private const val MOVING_SPEED_MS = 5f
    }
}
