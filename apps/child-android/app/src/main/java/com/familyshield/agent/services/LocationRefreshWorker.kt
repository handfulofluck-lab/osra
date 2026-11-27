package com.familyshield.agent.services

import android.Manifest
import android.content.Context
import android.content.pm.PackageManager
import android.os.Build
import android.util.Log
import androidx.core.content.ContextCompat
import androidx.work.CoroutineWorker
import androidx.work.WorkerParameters
import com.familyshield.agent.data.ConsentPolicy
import com.familyshield.agent.data.db.PendingPingEntity
import com.familyshield.agent.di.WorkerEntryPoint
import com.familyshield.agent.network.dto.LocationPingBatchDto
import com.familyshield.agent.network.dto.LocationPingDto
import com.google.android.gms.location.LocationServices
import com.google.android.gms.location.Priority
import dagger.hilt.android.EntryPointAccessors
import java.time.Instant
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withTimeoutOrNull

/**
 * Issue #1053: Doze-resilient periodic background location refresh (`<= 2.5-3 h` spacing).
 *
 * Runs inside WorkManager's `JobScheduler` maintenance window without creating a foreground service
 * (preserving Android 14+ background-FGS rules and `LocationServiceStartSitesTest`). Active phones
 * whose [LocationService] already uploaded within [LocationRefreshPolicy.FRESH_ENOUGH_MS] exit at
 * once without waking location hardware; idle/sleeping phones request a single balanced-power fix
 * (Wi-Fi/cell, never GNSS/GPS) bounded by [LocationRefreshPolicy.PERIODIC_FIX_TIMEOUT_MS], fall back
 * to `lastLocation` only per [LocationRefreshPolicy.choosePeriodicFix], and upload under
 * [LocationService.FLUSH_MUTEX] (persisting to Room on transient network failure).
 */
class LocationRefreshWorker(
    context: Context,
    params: WorkerParameters,
) : CoroutineWorker(context, params) {

    override suspend fun doWork(): Result {
        val deps = EntryPointAccessors.fromApplication(applicationContext, WorkerEntryPoint::class.java)
        val settings = deps.agentSettings()
        val consentState = deps.consentState()
        val api = deps.apiService()
        val dao = deps.database().pendingPingDao()

        val lastUploadedAtMs = settings.lastLocationUploadedAtMs()
        val decision = LocationRefreshPolicy.decide(
            isPaired = settings.isPaired(),
            consentPaused = consentState.isPaused(),
            hasFine = granted(Manifest.permission.ACCESS_FINE_LOCATION),
            hasCoarse = granted(Manifest.permission.ACCESS_COARSE_LOCATION),
            hasBackground = granted(Manifest.permission.ACCESS_BACKGROUND_LOCATION),
            apiLevel = Build.VERSION.SDK_INT,
            lastUploadedAtMs = lastUploadedAtMs,
            nowMs = System.currentTimeMillis(),
        )
        if (decision != LocationRefreshPolicy.Decision.FETCH) {
            return Result.success()
        }

        val fused = LocationServices.getFusedLocationProviderClient(applicationContext)
        val fetched = acquirePeriodicFix(
            fetchBalanced = {
                LocationFixFetcher.requestCurrentLocation(fused, Priority.PRIORITY_BALANCED_POWER_ACCURACY)
            },
            fetchLastLocation = {
                LocationFixFetcher.requestLastLocation(fused)
            },
            timeOf = { it.time },
            lastUploadedAtMs = lastUploadedAtMs,
        )
        val location = fetched.location ?: return Result.success()

        return LocationService.FLUSH_MUTEX.withLock {
            if (consentState.isPaused()) {
                runCatching { dao.clear() }
                return@withLock Result.success()
            }
            if (!settings.isPaired()) {
                return@withLock Result.success()
            }
            val fixTimeMs = location.time.takeIf { it > 0L } ?: System.currentTimeMillis()
            val ping = LocationPingDto(
                lat = location.latitude,
                lng = location.longitude,
                accuracyM = location.accuracy,
                timestamp = Instant.ofEpochMilli(fixTimeMs).toString(),
            )
            val stored = dao.all()
            val batch = stored.map {
                LocationPingDto(
                    lat = it.lat,
                    lng = it.lng,
                    accuracyM = it.accuracyM,
                    timestamp = Instant.ofEpochMilli(it.timestamp).toString(),
                )
            } + ping
            try {
                api.postLocationPings(LocationPingBatchDto(batch))
                if (stored.isNotEmpty()) dao.clear()
                val nowMs = System.currentTimeMillis()
                val latestBatchMs = maxOf(
                    fixTimeMs,
                    stored.maxOfOrNull { it.timestamp } ?: 0L,
                )
                runCatching {
                    settings.saveLastLocationUploadedAtMs(
                        LocationRefreshPolicy.mergedLastUploadedAtMs(
                            previousMs = settings.lastLocationUploadedAtMs(),
                            uploadedPingTimeMs = latestBatchMs,
                            nowMs = nowMs,
                        ),
                    )
                }
                Result.success()
            } catch (e: CancellationException) {
                throw e
            } catch (e: Exception) {
                consentState.onPollFailure(e)
                if (ConsentPolicy.httpStatusOf(e) == ConsentPolicy.HTTP_PRECONDITION_REQUIRED) {
                    runCatching { dao.clear() }
                    return@withLock Result.success()
                }
                Log.w(TAG, "periodic location upload failed; buffering ping in Room", e)
                runCatching {
                    dao.insertAll(
                        listOf(
                            PendingPingEntity(
                                lat = location.latitude,
                                lng = location.longitude,
                                accuracyM = location.accuracy,
                                timestamp = fixTimeMs,
                            ),
                        ),
                    )
                }
                Result.success()
            }
        }
    }

    private fun granted(permission: String): Boolean =
        ContextCompat.checkSelfPermission(applicationContext, permission) == PackageManager.PERMISSION_GRANTED

    companion object {
        /** Unique periodic work name registered in [com.familyshield.agent.data.WorkScheduler]. */
        const val WORK_NAME: String = "osra_location_refresh"

        private const val TAG: String = "LocationRefreshWorker"

        internal data class PeriodicFetchedFix<T>(
            val choice: LocationRefreshPolicy.Choice,
            val location: T?,
        )

        /**
         * Pure one-shot balanced acquisition + gated `lastLocation` fallback so the JVM suite can
         * test timeout bounding, cache selection, and cancellation without Google Play Services.
         */
        internal suspend fun <T> acquirePeriodicFix(
            fetchBalanced: suspend () -> T?,
            fetchLastLocation: suspend () -> T?,
            timeOf: (T) -> Long,
            lastUploadedAtMs: Long?,
            nowMs: () -> Long = { System.currentTimeMillis() },
            withTimeout: suspend (Long, suspend () -> T?) -> T? = { timeoutMs, block ->
                withTimeoutOrNull(timeoutMs) { block() }
            },
        ): PeriodicFetchedFix<T> {
            val fresh = try {
                withTimeout(LocationRefreshPolicy.PERIODIC_FIX_TIMEOUT_MS, fetchBalanced)
            } catch (e: CancellationException) {
                throw e
            } catch (_: Exception) {
                null
            }
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
            return when (
                val choice = LocationRefreshPolicy.choosePeriodicFix(
                    freshAvailable = fresh != null,
                    cachedTimeMs = cached?.let(timeOf),
                    lastUploadedAtMs = lastUploadedAtMs,
                    nowMs = now,
                )
            ) {
                LocationRefreshPolicy.Choice.FRESH -> PeriodicFetchedFix(choice, fresh)
                LocationRefreshPolicy.Choice.CACHED -> PeriodicFetchedFix(choice, cached)
                LocationRefreshPolicy.Choice.NONE -> PeriodicFetchedFix(choice, null)
            }
        }
    }
}
