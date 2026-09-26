package com.familyshield.agent.data

import com.familyshield.agent.network.ApiService
import com.familyshield.agent.network.dto.RuleSetDto
import com.squareup.moshi.Moshi
import com.google.firebase.messaging.FirebaseMessaging
import java.time.LocalDate
import java.time.ZonedDateTime
import javax.inject.Inject
import javax.inject.Singleton
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock

/**
 * Holds the latest [RuleSetDto], persists it as JSON in DataStore, refreshes it from the backend,
 * subscribes to the FCM topic `child:<childId>:rules` and answers [evaluate] calls from the
 * accessibility service. Thread-safe: refreshes are serialized with a [Mutex], daily counters live
 * in the pure [UsageCounters] helper. Counters are in-memory only (lost on reboot) and reset at
 * local midnight — the midnight WorkManager worker calls [resetIfNewDay] and evaluation self-heals
 * on date change. Also holds the pause-internet flag (Feature #11) and today's bonus minutes
 * (Feature #10), both consulted by [evaluate].
 */
@Singleton
class RuleRepository @Inject constructor(
    private val api: ApiService,
    private val settings: AgentSettings,
    private val moshi: Moshi,
    private val blocklist: BlocklistStore,
) {
    /** Outcome of evaluating a package against the active rule set. */
    enum class Decision { ALLOW, BLOCK, TIME_LIMIT_REACHED }

    private val engine = RuleEngine()
    private val appScope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    private val refreshMutex = Mutex()
    private val counters = UsageCounters()

    @Volatile private var cached: RuleSetDto? = null

    // Pause-the-internet state (Feature #11): set by CommandDispatcher on pause_internet /
    // resume_internet; consulted by [evaluate] so every non-always-allowed app is blocked.
    @Volatile private var pausedInternet = false

    // Bonus screen time granted today (Feature #10), in-memory only and reset at local midnight.
    // NOTE: persistence lives server-side (RuleSet.bonusMinutesToday, reset daily); a reboot
    // loses the local copy, which self-heals on the next rules refresh.
    private val bonusLock = Any()
    private var bonusMinutesToday = 0
    private var bonusDay: LocalDate? = null

    init {
        appScope.launch {
            cached = loadFromDisk()
            refresh()
        }
    }

    /** Returns the decision for [packageId] based on the cached rules, the blocklist and today's usage counters. */
    fun evaluate(packageId: String): Decision {
        val ruleSet = cached ?: return Decision.ALLOW
        val snapshot = counters.snapshot(System.currentTimeMillis())
        return engine.evaluate(
            ruleSet,
            packageId,
            ZonedDateTime.now(),
            snapshot,
            blocklist.apps(),
            pausedInternet = pausedInternet,
            bonusMinutes = bonusMinutes(),
        )
    }

    /** Enables or clears pause-the-internet (Feature #11); while paused every app except alwaysAllowedApps is blocked. */
    fun setPausedInternet(paused: Boolean) {
        pausedInternet = paused
    }

    /** Returns true while the internet is paused by the parent (Feature #11). */
    fun isInternetPaused(): Boolean = pausedInternet

    /** Feature #2: true unless the cached rule set explicitly disables social monitoring for [appKey] (absent key = enabled). */
    fun socialMonitoringEnabled(appKey: String): Boolean = cached?.socialMonitoring?.get(appKey) ?: true

    /** Feature #27: the parent-curated contact allowlist; empty means unknown-contact alerting is disabled. */
    fun contactAllowlist(): List<String> = cached?.contactAllowlist ?: emptyList()

    /** Adds [minutes] of bonus screen time for today only (Feature #10); non-positive values are ignored. */
    fun addBonusMinutes(minutes: Int) {
        if (minutes <= 0) return
        synchronized(bonusLock) {
            resetBonusIfNewDayLocked(LocalDate.now())
            bonusMinutesToday += minutes
        }
    }

    /** Returns the bonus minutes granted today (0 after local midnight). */
    private fun bonusMinutes(): Int = synchronized(bonusLock) {
        resetBonusIfNewDayLocked(LocalDate.now())
        bonusMinutesToday
    }

    private fun resetBonusIfNewDayLocked(today: LocalDate) {
        if (bonusDay != today) {
            bonusMinutesToday = 0
            bonusDay = today
        }
    }

    /** Updates the daily usage counters from a foreground-app event (called by UsageReporter). */
    fun onForegroundEvent(packageId: String, timestampMs: Long) {
        counters.onForegroundEvent(packageId, timestampMs)
    }

    /** Clears the daily counters when the local date has changed (no-op otherwise). */
    suspend fun resetIfNewDay() {
        counters.resetIfNewDay()
    }

    /** Feature #29: today's per-app minute counters for the live-activity feed. */
    fun minutesSnapshot(): Map<String, Int> = counters.snapshot(System.currentTimeMillis())

    /**
     * Fetches the latest rule set from GET /v1/rules/<childId>, caches it, persists it as JSON in
     * DataStore and (re)subscribes to the FCM rules topic. Returns the cached set on failure.
     */
    suspend fun refresh(): RuleSetDto? {
        val childId = settings.childId() ?: return cached
        return refreshMutex.withLock {
            val updated = try {
                api.getRules(childId)
            } catch (e: CancellationException) {
                throw e // NOTE: never swallow coroutine cancellation
            } catch (e: Exception) {
                return@withLock cached
            }
            cached = updated
            runCatching { settings.saveRulesJson(moshi.adapter(RuleSetDto::class.java).toJson(updated)) }
            runCatching { FirebaseMessaging.getInstance().subscribeToTopic("child:$childId:rules") }
            updated
        }
    }

    /** Returns the most recently known rule set, loading it from disk if necessary. */
    suspend fun currentRules(): RuleSetDto? {
        cached?.let { return it }
        return loadFromDisk().also { cached = it }
    }

    private suspend fun loadFromDisk(): RuleSetDto? {
        val json = settings.rulesJson() ?: return null
        return runCatching { moshi.adapter(RuleSetDto::class.java).fromJson(json) }.getOrNull()
    }
}
