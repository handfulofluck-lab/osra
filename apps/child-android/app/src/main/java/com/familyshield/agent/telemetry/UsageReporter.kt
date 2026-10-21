package com.familyshield.agent.telemetry

import android.Manifest
import android.app.usage.UsageStatsManager
import android.content.Context
import android.content.pm.PackageManager
import android.os.BatteryManager
import android.os.Build
import android.util.Log
import androidx.core.content.ContextCompat
import com.familyshield.agent.comms.CommsConsentPolicy
import com.familyshield.agent.comms.CommsWatermarkPolicy
import com.familyshield.agent.data.AgentSettings
import com.familyshield.agent.data.ConsentPolicy
import com.familyshield.agent.data.ConsentState
import com.familyshield.agent.data.RuleRepository
import com.familyshield.agent.data.db.AgentStateEntity
import com.familyshield.agent.data.db.FamilyShieldDatabase
import com.familyshield.agent.data.db.UsageEventEntity
import com.familyshield.agent.network.ApiService
import com.familyshield.agent.network.dto.ActivityEventBatchDto
import com.familyshield.agent.network.dto.TelemetryDto
import dagger.hilt.android.qualifiers.ApplicationContext
import java.time.LocalDate
import java.time.ZoneId
import java.util.concurrent.atomic.AtomicInteger
import javax.inject.Inject
import javax.inject.Singleton
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.launch

/**
 * Records foreground-app transitions (Room `usage_events`) and periodically aggregates
 * per-app minutes, total minutes and an unlock counter into POST /v1/devices/<id>/telemetry.
 * Minutes are computed from consecutive event gaps capped at 5 min. A UsageStatsManager
 * backfill runs behind try/catch because the PACKAGE_USAGE_STATS permission is not guaranteed.
 * Also posts the Feature #29 live-activity app_usage event from the LocationService 60 s loop.
 */
@Singleton
class UsageReporter @Inject constructor(
    @ApplicationContext private val context: Context,
    private val db: FamilyShieldDatabase,
    private val api: ApiService,
    private val settings: AgentSettings,
    private val rules: RuleRepository,
    private val consent: ConsentState,
) {
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)

    @Volatile private var lastPkg: String? = null
    @Volatile private var lastTs: Long = 0L
    private val unlockCounter = AtomicInteger(0)

    /** Records one foreground transition at [ts] (epoch millis); safe to call on the main thread. */
    fun recordForeground(pkg: String, ts: Long) {
        val prevPkg = lastPkg
        val prevTs = lastTs
        lastPkg = pkg
        lastTs = ts
        // Issue #265: the foreground package is still tracked while paused -- the lock overlay's "what
        // is open now" and the live-activity payload read it, and that is not collection.
        if (consent.isPaused()) return
        // `rules.onForegroundEvent` is NOT enforcement: `RuleRepository.decide` returns ALLOW while
        // consent is paused, so it only feeds the daily minute counter (`UsageCounters`, which saves to
        // settings). Calling it while paused credited the withdrawn window to the app that was open, and
        // the first live-activity post after a re-grant then reported those minutes as today's total
        // (#266 review, D1). The most that can still leak is one open gap, capped at
        // `UsageCounters.MAX_GAP_MINUTES` (5).
        rules.onForegroundEvent(pkg, ts)
        // NOTE: the accessibility stream has no screen-on/off events, so a "new session"
        // (counted as an unlock) is a package change or the first event after a >60 s gap.
        if (prevPkg == null || prevPkg != pkg || ts - prevTs > 60_000L) {
            unlockCounter.incrementAndGet()
        }
        scope.launch { db.usageEventDao().insert(UsageEventEntity(packageId = pkg, timestamp = ts)) }
    }

    /** Aggregates the usage since the last successful run and uploads the delta; no-op without a device id. */
    suspend fun aggregateAndUpload() {
        val deviceId = settings.deviceId() ?: return
        val dao = db.usageEventDao()
        val stateDao = db.agentStateDao()
        // Issue #265: the same epoch rule the comms streams use (#257), not a copy of it. While consent
        // is withdrawn this returns null and nothing moves; at the first upload after a re-grant it
        // returns the moment the phone learned consent came back, so the paused window is dropped here
        // rather than uploaded as today's screen time.
        val epoch = consent.pauseEpoch()
        val storedEpoch = CommsWatermarkPolicy.normalize(stateDao.get(KEY_CONSENT_EPOCH))
        CommsConsentPolicy.resetTo(
            storedEpoch = storedEpoch,
            epoch = epoch,
            paused = consent.isPaused(),
            resumedAtMs = consent.resumedAtMs(),
        )?.let { restartFrom ->
            stateDao.set(AgentStateEntity(KEY_WATERMARK, restartFrom))
            dao.deleteOlderThan(restartFrom)
            unlockCounter.set(0)
            stateDao.set(AgentStateEntity(KEY_CONSENT_EPOCH, epoch))
            // Issue #267: a re-grant establishes a UsageStats baseline instead of adding anything, so the
            // withdrawn window and the morning before the grant are excluded rather than uploaded — this
            // replaces the "skip the backfill on a re-grant day" rule from #266.
            usageStatsTotals()?.let { (bucketBegin, totals) -> settings.setUsageStatsSnapshot(bucketBegin, totals) }
        }
        if (consent.isPaused()) return // ADR-0008 §3: no telemetry while consent is withdrawn
        val watermark = stateDao.get(KEY_WATERMARK) ?: dao.oldestTimestamp() ?: return
        val windowEnd = System.currentTimeMillis()
        val events = dao.since(watermark)

        val perApp = computePerAppMinutes(events, windowEnd).toMutableMap()
        backfillFromUsageStats(perApp)

        val unlocks = unlockCounter.getAndSet(0)
        val total = perApp.values.sum()
        // NOTE: anchor the cleanup to the last aggregated event. Events arriving between the
        // snapshot above and this delete would otherwise be removed unsent (previously the
        // delete/watermark used windowEnd, which raced with concurrent inserts).
        val newWatermark = (events.lastOrNull()?.timestamp ?: windowEnd) + 1
        // Always POST: even idle, batteryPct is the device heartbeat that keeps
        // lastSeen/battery fresh for the parent app.
        try {
            val grant = currentLocationGrant()
            api.postTelemetry(deviceId, TelemetryDto(perAppMinutes = perApp, totalMinutes = total, unlockCount = unlocks, batteryPct = currentBatteryPct(), locationGrant = grant))
            // Issue #221: the periodic upload also counts as a report, so the expedited path does not
            // re-send the same value on the next resume.
            settings.recordReportedLocationGrant(grant)
            // NOTE: watermark moves only on success...
            dao.deleteOlderThan(newWatermark)
            stateDao.set(AgentStateEntity(KEY_WATERMARK, newWatermark))
        } catch (e: CancellationException) {
            unlockCounter.addAndGet(unlocks) // ...and the unlock counter is restored on failure
            throw e // NOTE: never swallow coroutine cancellation
        } catch (e: Exception) {
            unlockCounter.addAndGet(unlocks) // re-count on the next cycle
        }
    }

    /**
     * Posts a live-activity snapshot (Feature #29) to POST /v1/devices/<id>/activity every ~60 s
     * from the LocationService flush loop: one app_usage event with the foreground package (or
     * "idle") and today's total minutes across apps. Failures are logged and swallowed.
     */
    suspend fun postLiveActivity() {
        val deviceId = settings.deviceId() ?: return
        // Issue #265: this had no consent check while its siblings did, so a withdrawn phone kept
        // posting the foreground app every 60 s, the server answered 428, and the stack was logged
        // once a minute. ADR-0008 decision 3 pauses collection, not just enforcement.
        if (consent.isPaused()) return
        val event = liveActivityPayload(rules.minutesSnapshot(), currentForeground())
        val liveEvent = event.copy(payload = event.payload + ("live" to true))
        try {
            api.postActivityEvents(deviceId, ActivityEventBatchDto(listOf(liveEvent)))
        } catch (e: CancellationException) {
            throw e // NOTE: never swallow coroutine cancellation
        } catch (e: Exception) {
            // A withdrawal between the check above and the post is still the expected answer, not a
            // warning: one line at INFO, no stack, the same rule the command poll follows (#263).
            if (ConsentPolicy.httpStatusOf(e) == 428) return
            Log.w(TAG, "live activity post failed", e)
        }
    }

    /** Last foreground package recorded by the accessibility stream, or null before the first transition. */
    fun currentForeground(): String? = lastPkg

    /** Current battery percentage from the system BatteryManager, or null when unknown. */
    private fun currentBatteryPct(): Int? {
        return try {
            val bm = context.getSystemService(Context.BATTERY_SERVICE) as BatteryManager
            bm.getIntProperty(BatteryManager.BATTERY_PROPERTY_CAPACITY).takeIf { it in 0..100 }
        } catch (e: Exception) {
            null
        }
    }

    /**
     * Issue #221 (D1 follow-up): upload the grant immediately when it changed, independent of usage.
     *
     * The periodic path ([aggregateAndUpload]) returns early while there are no usage events, so on a
     * phone without accessibility the server could go a long time without learning that location was
     * granted — and refuse a Locate the phone could have answered. Called from the pairing screen's
     * resume and from the location-permission callbacks.
     */
    suspend fun reportLocationGrantIfChanged() {
        val deviceId = settings.deviceId() ?: return
        if (consent.isPaused()) return // ADR-0008 §3: no telemetry while consent is withdrawn
        val reporter = LocationGrantReporter(
            lastReported = { settings.reportedLocationGrant() },
            recordReported = { settings.recordReportedLocationGrant(it) },
            upload = { grant ->
                api.postTelemetry(
                    deviceId,
                    TelemetryDto(
                        perAppMinutes = emptyMap(),
                        totalMinutes = 0,
                        unlockCount = 0,
                        batteryPct = currentBatteryPct(),
                        locationGrant = grant,
                    ),
                )
            },
        )
        try {
            reporter.reportIfChanged(currentLocationGrant())
        } catch (e: CancellationException) {
            throw e // NOTE: never swallow coroutine cancellation
        } catch (e: Exception) {
            // Left unrecorded on purpose: the next resume retries with the same value.
            Log.w(TAG, "location grant report failed", e)
        }
    }

    /**
     * Issue #221 (D1): the location grant the server stores so it can answer a `locate_now` at once.
     * Read fresh on every tick — the parent can change the grant while the process runs, and a cached
     * value would make the server refuse (or accept) the wrong state.
     */
    private fun currentLocationGrant(): String = LocationGrantState.classify(
        hasFineLocation = granted(Manifest.permission.ACCESS_FINE_LOCATION),
        hasCoarseLocation = granted(Manifest.permission.ACCESS_COARSE_LOCATION),
        hasBackgroundLocation = granted(Manifest.permission.ACCESS_BACKGROUND_LOCATION),
        apiLevel = Build.VERSION.SDK_INT,
    )

    private fun granted(permission: String): Boolean =
        ContextCompat.checkSelfPermission(context, permission) == PackageManager.PERMISSION_GRANTED

    /**
     * Adds UsageStatsManager totals for packages missing from the event stream (best effort).
     *
     * Issue #266 review (D2): `queryUsageStats(INTERVAL_DAILY, start, now)` returns **whole buckets** —
     * the platform includes the interval a timestamp falls in, so a floor in the middle of the day does
     * not exclude the morning. And since a paused device writes no Room rows, an app used only during the
     * withdrawal looks "missing from the event stream" and its whole-day total would be added back. Both
     * are the withdrawn window reaching the parent, so the backfill is skipped entirely on a re-grant day.
     * The cost: apps the accessibility stream missed go uncounted until the next day. That is the right
     * trade — an under-count a parent can see is better than a leak they cannot.
     */
    /**
     * Issue #267: Android's per-package totals **for the current bucket**, or null without usage access.
     *
     * `INTERVAL_DAILY` returns whole buckets and rolls them at a time the device picks — measured at
     * 20:07 on the Flip4, not local midnight — so the query can return the old bucket and the new one
     * side by side. Keeping the entry with the greatest `firstTimeStamp` (the bucket's start, per `UsageStats`) per package is what makes the
     * bucket identity below correct; `associate` would keep whichever came last.
     */
    private fun usageStatsTotals(): Pair<Long, Map<String, Int>>? = try {
        val startOfDay = LocalDate.now().atStartOfDay(ZoneId.systemDefault()).toInstant().toEpochMilli()
        val usm = context.getSystemService(Context.USAGE_STATS_SERVICE) as UsageStatsManager
        val stats = usm.queryUsageStats(UsageStatsManager.INTERVAL_DAILY, startOfDay, System.currentTimeMillis())
            ?: emptyList()
        val newestBegin = stats.maxOfOrNull { it.firstTimeStamp } ?: 0L
        val bucket = stats.filter { it.firstTimeStamp == newestBegin }
        newestBegin to bucket.associate { it.packageName to (it.totalTimeInForeground / 60_000L).toInt() }
    } catch (t: Throwable) {
        // Stats permission not granted (or OEM restriction) — event-based numbers only.
        null
    }

    /**
     * Adds UsageStatsManager totals for packages the event stream missed — as a **delta** (#267).
     *
     * The upload is a delta and the server adds every upload to the day, so adding Android's whole-day
     * total for an app that this window's events did not mention added that app's morning again on every
     * later upload. The totals are now treated as running counters: what is sent is the increase since the
     * last snapshot, and every package's total is recorded so a later window without it adds only its
     * increase. A total below the snapshot means the day rolled over, and the whole total is new.
     */
    private suspend fun backfillFromUsageStats(perApp: MutableMap<String, Int>) {
        val (bucketBegin, totals) = usageStatsTotals() ?: return
        val (storedBucket, lastSeen) = settings.usageStatsSnapshot()
        val hasSnapshot = storedBucket != null
        val sameBucket = storedBucket == bucketBegin
        for ((pkg, total) in totals) {
            if (perApp.containsKey(pkg)) continue // counted from this window's events already
            val delta = UsageStatsDelta.deltaForUpload(total, lastSeen[pkg], sameBucket, hasSnapshot)
            if (delta > 0) perApp[pkg] = (perApp[pkg] ?: 0) + delta
        }
        // Recorded for every package, including those the events covered: a later window without one of
        // them must add only what Android saw after this upload. With no snapshot this is the baseline
        // and nothing was added, which is #229's rule for the first upload after a pairing.
        settings.setUsageStatsSnapshot(bucketBegin, totals)
    }

    companion object {
        /** Unique work name for the 15-min aggregation job. */
        const val WORK_NAME: String = "telemetry_upload"

        private const val KEY_WATERMARK = "telemetry_watermark"

        /** Issue #265: the consent epoch last applied to this stream, separate from the comms ones. */
        private const val KEY_CONSENT_EPOCH = "telemetry_consent_epoch"

        private const val TAG = "UsageReporter"
    }
}
