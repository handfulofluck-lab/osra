package com.familyshield.agent.data

import com.familyshield.agent.data.db.UsageEventDao
import com.familyshield.agent.enforcement.EssentialPackages
import com.familyshield.agent.enforcement.PackageFacts
import com.familyshield.agent.network.ApiService
import com.familyshield.agent.network.dto.RuleSetDto
import com.squareup.moshi.Moshi
import com.squareup.moshi.Types
import com.google.firebase.messaging.FirebaseMessaging
import java.time.LocalDate
import java.time.ZoneId
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
 * in the pure [UsageCounters] helper. Counters are rebuilt and persisted across reboots (AND-02) and reset at
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
    private val usageDao: UsageEventDao? = null,
    private val consent: ConsentState,
    /** The OS view of a package (issue #165): the essential gate consults the HOME role, not just names. */
    private val packageFacts: PackageFacts,
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
            rebuildCounters()
            refresh()
        }
    }

    /** Returns the decision for [packageId] based on the cached rules, the blocklist and today's usage counters. */
    fun evaluate(packageId: String): Decision {
        val ruleSet = cached
        return decide(
            packageId = packageId,
            ruleSet = ruleSet,
            paired = settings.isPairedSync(),
            consentPaused = consent.isPaused(),
            essential = { EssentialPackages.isEssential(it, packageFacts) },
        ) { rules ->
            engine.evaluate(
                rules,
                packageId,
                ZonedDateTime.now(),
                counters.snapshot(System.currentTimeMillis()),
                blocklist.apps(),
                pausedInternet = pausedInternet,
                bonusMinutes = bonusMinutes(),
            )
        }
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
        appScope.launch { persistCounters() }
    }

    /** Clears the daily counters when the local date has changed (no-op otherwise). */
    suspend fun resetIfNewDay() {
        counters.resetIfNewDay()
        persistCounters(LocalDate.now())
    }

    /** Rebuilds daily counters on startup from persisted settings and Room usage_events (AND-02). */
    suspend fun rebuildCounters(today: LocalDate = LocalDate.now()) {
        val savedDate = settings.todayUsageDate()
        if (savedDate == today.toString()) {
            val json = settings.todayUsageJson()
            if (!json.isNullOrBlank()) {
                val map = runCatching { moshi.adapter<Map<String, Long>>(LONG_MAP).fromJson(json) }.getOrNull()
                if (map != null) {
                    counters.restore(persistedUsageMs(map, settings.todayUsageUnit()), today)
                }
            }
        }
        usageDao?.let { dao ->
            val startOfDayMs = today.atStartOfDay(ZoneId.systemDefault()).toInstant().toEpochMilli()
            val events = runCatching { dao.since(startOfDayMs) }.getOrDefault(emptyList())
            if (events.isNotEmpty()) {
                val pairs = events.map { it.packageId to it.timestamp }
                counters.rebuildFromEvents(pairs, today)
            }
        }
        persistCounters(today)
    }

    /** Persists today's counters snapshot (milliseconds) to AgentSettings (AND-02, #276). */
    suspend fun persistCounters(today: LocalDate = LocalDate.now()) {
        val snapshot = counters.snapshotMs(System.currentTimeMillis(), today)
        val json = moshi.adapter<Map<String, Long>>(LONG_MAP).toJson(snapshot)
        runCatching { settings.saveTodayUsage(today.toString(), json) }
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
                // ADR-0008 §3: a 428 here means consent was withdrawn — pause, keep the cached rules dormant.
                consent.onPollFailure(e)
                return@withLock cached
            }
            consent.onPollStatus(200)
            cached = updated
            runCatching { settings.saveRulesJson(moshi.adapter(RuleSetDto::class.java).toJson(updated)) }
            runCatching { FirebaseMessaging.getInstance().subscribeToTopic("child:$childId:rules") }
            updated
        }
    }

    /** Fire-and-forget refresh (used after consent is re-granted). */
    fun refreshAsync() {
        appScope.launch { refresh() }
    }

    /** The cached rule set without touching disk (null before the first load); for services on the hot path. */
    fun cachedRules(): RuleSetDto? = cached

    /** Returns the most recently known rule set, loading it from disk if necessary. */
    suspend fun currentRules(): RuleSetDto? {
        cached?.let { return it }
        return loadFromDisk().also { cached = it }
    }

    private suspend fun loadFromDisk(): RuleSetDto? {
        val json = settings.rulesJson() ?: return null
        return runCatching { moshi.adapter(RuleSetDto::class.java).fromJson(json) }.getOrNull()
    }

    companion object {
        private val LONG_MAP: java.lang.reflect.Type =
            Types.newParameterizedType(Map::class.java, String::class.java, Long::class.javaObjectType)

        /**
         * The launcher, the system UI and the call surfaces are exempt from every block rule, not only
         * from fail-closed (issue #165). The list lives in [EssentialPackages] so the lock, the
         * decision path and the overlay guard cannot drift apart.
         */
        fun isEssentialApp(packageId: String): Boolean = EssentialPackages.isEssential(packageId)

        /**
         * #276: the persisted snapshot is milliseconds now, but a build before it wrote whole
         * minutes and no unit. Read those as minutes × 60_000 — reading them as ms instead would
         * leave a phone that updates mid-day with 1/60 of the count it had.
         */
        internal fun persistedUsageMs(values: Map<String, Long>, unit: String?): Map<String, Long> =
            if (unit == AgentSettings.USAGE_UNIT_MS) values else values.mapValues { it.value * 60_000L }

        /**
         * Pure core of [evaluate] (JVM-tested, issue #165), in order: consent, then the essential
         * screens, then fail-closed for an empty cache, then [rulesDecision] for the real rules.
         *
         * The order is the fix. Before it, an empty cache failed closed with the essential list and
         * the rules path never asked it, so a bedtime rule answered BLOCK for the home screen — the
         * overlay covered the launcher and the child could not press Home, reach the dialer, or see
         * what would still work. An essential screen is now ALLOW before any rule is consulted.
         *
         * [essential] is the OS-aware form on the real device ([EssentialPackages.isEssential] with
         * [PackageFacts]), so a launcher the name table does not know is still exempt when the OS says
         * it holds HOME. It stays a predicate so this core has no Android dependency.
         */
        internal fun decide(
            packageId: String,
            ruleSet: RuleSetDto?,
            paired: Boolean,
            consentPaused: Boolean,
            essential: (String) -> Boolean = { EssentialPackages.isEssential(it) },
            rulesDecision: (RuleSetDto) -> Decision,
        ): Decision {
            // ADR-0008 §3: no enforcement while the parent has withdrawn consent.
            if (consentPaused) return Decision.ALLOW
            if (essential(packageId)) return Decision.ALLOW
            if (ruleSet == null) {
                // AND-03: Fail-closed when paired but no rules are cached yet — for apps only.
                return if (paired) Decision.BLOCK else Decision.ALLOW
            }
            return rulesDecision(ruleSet)
        }
    }
}
