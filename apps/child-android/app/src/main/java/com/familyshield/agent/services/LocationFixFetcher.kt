package com.familyshield.agent.services

import android.Manifest
import android.content.Context
import android.content.pm.PackageManager
import android.location.Location
import android.util.Log
import androidx.core.content.ContextCompat
import com.familyshield.agent.commands.LocateFix
import com.familyshield.agent.commands.LocatePolicy
import com.familyshield.agent.data.AgentSettings
import com.familyshield.agent.data.ConsentState
import com.familyshield.agent.network.ApiService
import com.familyshield.agent.network.dto.LocationPingBatchDto
import com.familyshield.agent.network.dto.LocationPingDto
import com.google.android.gms.location.FusedLocationProviderClient
import com.google.android.gms.location.LocationServices
import com.google.android.gms.location.Priority
import com.google.android.gms.tasks.CancellationTokenSource
import java.time.Instant
import kotlin.coroutines.resume
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withTimeoutOrNull

/**
 * Issue #1054: shared one-shot location acquisition (two-stage fresh fix + recent cached fallback)
 * used by [LocationService.locateNowOnce] and by [com.familyshield.agent.commands.CommandDispatcher]'s
 * direct background fallback when Android refuses `startForegroundService(LocationService)`.
 *
 * Stage 1: `PRIORITY_HIGH_ACCURACY` for up to [LocatePolicy.HIGH_ACCURACY_TIMEOUT_MS] (15 s).
 * Stage 2: if null/timeout, `PRIORITY_BALANCED_POWER_ACCURACY` for up to [LocatePolicy.BALANCED_FALLBACK_TIMEOUT_MS] (10 s).
 * Stage 3: `lastLocation` if its age is `<=` [LocatePolicy.MAX_CACHED_AGE_MS] (5 min); else [LocatePolicy.Choice.NONE].
 */
object LocationFixFetcher {
    private const val TAG = "LocationFixFetcher"

    data class FetchedFix<T>(
        val choice: LocatePolicy.Choice,
        val location: T?,
        val fix: LocateFix?,
    )

    /**
     * Pure two-stage fresh fix + recent cached fallback resolver so the JVM suite can test every
     * stage transition, timeout budget and cached-age cutoff without Google Play Services.
     */
    internal suspend fun <T> acquireFix(
        fetchHighAccuracy: suspend () -> T?,
        fetchBalanced: suspend () -> T?,
        fetchLastLocation: suspend () -> T?,
        timeOf: (T) -> Long,
        nowMs: () -> Long = { System.currentTimeMillis() },
        withTimeout: suspend (Long, suspend () -> T?) -> T? = { timeoutMs, block ->
            withTimeoutOrNull(timeoutMs) { block() }
        },
    ): FetchedFix<T> {
        val highAccuracy = runStage(LocatePolicy.HIGH_ACCURACY_TIMEOUT_MS, withTimeout, fetchHighAccuracy)
        val balanced = if (highAccuracy == null) {
            runStage(LocatePolicy.BALANCED_FALLBACK_TIMEOUT_MS, withTimeout, fetchBalanced)
        } else {
            null
        }
        val fresh = highAccuracy ?: balanced
        val cached = if (fresh == null) {
            try {
                fetchLastLocation()
            } catch (e: CancellationException) {
                throw e
            } catch (_: Exception) {
                null
            }
        } else {
            null
        }
        val now = nowMs()
        return when (LocatePolicy.choose(fresh != null, cached?.let(timeOf), now)) {
            LocatePolicy.Choice.FRESH -> FetchedFix(LocatePolicy.Choice.FRESH, fresh, LocateFix.FRESH)
            LocatePolicy.Choice.CACHED -> FetchedFix(LocatePolicy.Choice.CACHED, cached, LocateFix.CACHED)
            LocatePolicy.Choice.NONE -> FetchedFix(LocatePolicy.Choice.NONE, null, null)
        }
    }

    private suspend fun <T> runStage(
        timeoutMs: Long,
        withTimeout: suspend (Long, suspend () -> T?) -> T?,
        block: suspend () -> T?,
    ): T? = try {
        withTimeout(timeoutMs, block)
    } catch (e: CancellationException) {
        throw e
    } catch (_: Exception) {
        null
    }

    /** Acquires a one-shot [Location] from [fused] using the two-stage fresh + cache strategy. */
    suspend fun fetchLocation(fused: FusedLocationProviderClient): FetchedFix<Location> = acquireFix(
        fetchHighAccuracy = { requestCurrentLocation(fused, Priority.PRIORITY_HIGH_ACCURACY) },
        fetchBalanced = { requestCurrentLocation(fused, Priority.PRIORITY_BALANCED_POWER_ACCURACY) },
        fetchLastLocation = { requestLastLocation(fused) },
        timeOf = { it.time },
    )

    /**
     * Direct one-shot fallback when `startForegroundService(LocationService)` throws on API 31+ in
     * background. Respects consent pause (ADR-0008 §3) and location permission checks, uploads the
     * obtained fix under [LocationService.FLUSH_MUTEX], and reports `(fix, uploaded)` to [onComplete]
     * so the dispatcher calls `ackLocateNow`.
     */
    suspend fun runDirectLocate(
        context: Context,
        api: ApiService,
        consentState: ConsentState,
        settings: AgentSettings? = null,
        onComplete: (LocateFix?, Boolean) -> Unit,
    ) {
        if (consentState.isPaused()) {
            onComplete(null, false)
            return
        }
        val hasGrant = ContextCompat.checkSelfPermission(context, Manifest.permission.ACCESS_FINE_LOCATION) ==
            PackageManager.PERMISSION_GRANTED ||
            ContextCompat.checkSelfPermission(context, Manifest.permission.ACCESS_COARSE_LOCATION) ==
            PackageManager.PERMISSION_GRANTED
        if (!hasGrant) {
            onComplete(null, false)
            return
        }
        val fused = LocationServices.getFusedLocationProviderClient(context)
        val fetched = fetchLocation(fused)
        val location = fetched.location
        val fix = fetched.fix
        if (location == null || fix == null) {
            Log.w(TAG, "locate_now (direct fallback): no fix within the timeout and nothing recent cached")
            onComplete(null, false)
            return
        }
        val uploaded = uploadSingleLocation(location, api, consentState, settings)
        if (!uploaded) {
            Log.w(TAG, "locate_now (direct fallback): fix obtained but not uploaded; no ack, the command is re-offered at 120 s")
        }
        onComplete(fix, uploaded)
    }

    private suspend fun uploadSingleLocation(
        location: Location,
        api: ApiService,
        consentState: ConsentState,
        settings: AgentSettings?,
    ): Boolean = LocationService.FLUSH_MUTEX.withLock {
        if (consentState.isPaused()) return@withLock false
        val ping = LocationPingDto(
            lat = location.latitude,
            lng = location.longitude,
            accuracyM = location.accuracy,
            timestamp = Instant.ofEpochMilli(location.time).toString(),
        )
        try {
            api.postLocationPings(LocationPingBatchDto(listOf(ping)))
            if (settings != null) {
                val nowMs = System.currentTimeMillis()
                val uploadedMs = location.time.takeIf { it > 0L } ?: nowMs
                runCatching {
                    settings.saveLastLocationUploadedAtMs(
                        LocationRefreshPolicy.mergedLastUploadedAtMs(
                            previousMs = settings.lastLocationUploadedAtMs(),
                            uploadedPingTimeMs = uploadedMs,
                            nowMs = nowMs,
                        ),
                    )
                }
            }
            true
        } catch (e: CancellationException) {
            throw e
        } catch (e: Exception) {
            Log.w(TAG, "locate_now (direct fallback): ping upload failed", e)
            false
        }
    }

    internal suspend fun requestCurrentLocation(
        fused: FusedLocationProviderClient,
        priority: Int,
    ): Location? = suspendCancellableCoroutine { cont ->
        val cts = CancellationTokenSource()
        cont.invokeOnCancellation { cts.cancel() }
        try {
            fused.getCurrentLocation(priority, cts.token)
                .addOnSuccessListener { if (cont.isActive) cont.resume(it) }
                .addOnFailureListener { if (cont.isActive) cont.resume(null) }
                .addOnCanceledListener { if (cont.isActive) cont.resume(null) }
        } catch (_: SecurityException) {
            if (cont.isActive) cont.resume(null)
        }
    }

    internal suspend fun requestLastLocation(fused: FusedLocationProviderClient): Location? =
        suspendCancellableCoroutine { cont ->
            try {
                fused.lastLocation
                    .addOnSuccessListener { if (cont.isActive) cont.resume(it) }
                    .addOnFailureListener { if (cont.isActive) cont.resume(null) }
                    .addOnCanceledListener { if (cont.isActive) cont.resume(null) }
            } catch (_: SecurityException) {
                if (cont.isActive) cont.resume(null)
            }
        }
}
