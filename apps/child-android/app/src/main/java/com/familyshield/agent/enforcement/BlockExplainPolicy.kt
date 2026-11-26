package com.familyshield.agent.enforcement

import com.familyshield.agent.data.RuleEngine
import com.familyshield.agent.data.WindowKind
import com.familyshield.agent.data.WindowReason
import com.familyshield.agent.network.dto.RuleSetDto
import java.time.DayOfWeek
import java.time.LocalDateTime
import java.time.LocalTime
import java.time.ZonedDateTime
import java.time.format.DateTimeFormatter
import java.util.Locale

/** Exact rule cause holding a blocked app shut on C-02 (#1179). */
enum class BlockCause {
    DAILY_LIMIT,
    APP_LIMIT,
    BEDTIME,
    SCHOOL,
    ROUTINE,
    PAUSED_INTERNET,
    APP_BLOCKED,
}

/**
 * Pure explanation of why [packageId] is paused right now, when it returns (later of all active
 * rules, or null if an indefinite rule applies), whether daily-limit extra time can be asked for
 * (G3: daily limit ONLY), and which parent-allowed apps remain open.
 */
data class BlockExplanation(
    val cause: BlockCause,
    val routineName: String? = null,
    val usedMinutes: Int? = null,
    val limitMinutes: Int? = null,
    /** 24-hour Western-digit "HH:mm" when a deterministic return time exists; null when indefinite. */
    val backAtTime: String? = null,
    /** True when [backAtTime] falls on a later calendar day than now. */
    val backAtTomorrow: Boolean = false,
    /** G3 (Karim 26 Nov 17:02): true ONLY when the daily screen-time limit is the sole active blocker. */
    val canAskForMoreTime: Boolean = false,
    /** Parent-mandated always-allowed packages (excluding the blocked app and OSRA itself). */
    val stillOpenPackages: List<String> = emptyList(),
)

/** Payload posted to `/v1/alerts/internal` when the child taps the C-02 primary request CTA (G2). */
data class ChildRequestPayload(
    val title: String,
    val body: String,
    val metadata: Map<String, String>,
)

/** Plain-language summary of active family rules for the C-02 "See my rules" sheet. */
data class ChildRulesSummary(
    val dailyLimitMinutes: Int?,
    val dailyUsedMinutes: Int,
    val bedtimeWindow: Pair<String, String>?,
    val schoolWindow: Pair<String, String>?,
    val routineNames: List<String>,
)

/**
 * Pure JVM policy for C-02 Time's up / blocked (#1179):
 * - Computes the exact blocking cause from the live [RuleSetDto] (never a generic "Time's up").
 * - Computes "Back again" as the **later of all active rules** (never promises a return time when
 *   an indefinite block or pause is active).
 * - Enforces G3 (Karim 17:02): "Ask for 15 more minutes of screen time" appears ONLY for
 *   [BlockCause.DAILY_LIMIT], never for per-app limits, routines, bedtime, school, pause, or block.
 * - Produces the exact G2 wire metadata (`requestType: "time"` + `minutes`, or `requestType: "access"`).
 */
object BlockExplainPolicy {

    private const val LRI: Char = '\u2066'
    private const val FSI: Char = '\u2068'
    private const val PDI: Char = '\u2069'
    private const val MAX_STILL_OPEN_APPS = 3

    /** G2/G3 (Claude 17:28 + Codex 17:37): only 15 or 30 minutes are emitted for daily-limit time requests. */
    val ALLOWED_TIME_REQUEST_MINUTES: Set<Int> = setOf(15, 30)

    private val HH_MM: DateTimeFormatter = DateTimeFormatter.ofPattern("HH:mm", Locale.US)

    /** Wraps app names, numbers, and clock times in LRI...PDI for RTL safety. */
    fun ltrIsolate(value: String): String = "$LRI${value.trim()}$PDI"

    /**
     * Wraps an entire clock range ("21:00 – 07:00") in one non-breaking LRI...PDI unit so RTL
     * preserves order and narrow 320 dp / 200% layouts move the range as a whole instead of
     * wrapping the end time onto a separate line (Codex #1188 B2).
     */
    fun ltrRange(start: String, end: String): String =
        ltrIsolate("${start.trim()}\u00A0\u2060–\u2060\u00A0${end.trim()}")

    /** Wraps routine or adult names in FSI...PDI so their own script sets direction. */
    fun firstStrongIsolate(value: String): String = "$FSI${value.trim()}$PDI"

    fun explain(
        ruleSet: RuleSetDto?,
        packageId: String,
        now: ZonedDateTime,
        minutesUsedToday: Map<String, Int>,
        blocklist: Map<String, String>,
        pausedInternet: Boolean,
        bonusMinutes: Int,
        fallbackReason: String,
        fallbackWindow: WindowReason?,
        declaresVpnService: Boolean = false,
        ownPackage: String = EssentialPackages.OWN_PACKAGE,
    ): BlockExplanation {
        val stillOpen = ruleSet?.alwaysAllowedApps
            .orEmpty()
            .asSequence()
            .map { it.trim() }
            .filter { it.isNotEmpty() && it != packageId && it != ownPackage }
            .distinct()
            .take(MAX_STILL_OPEN_APPS)
            .toList()

        if (ruleSet == null) {
            return fallbackExplanation(fallbackReason, fallbackWindow, now.toLocalDateTime(), stillOpen)
        }

        val local = now.toLocalDateTime()
        val time = local.toLocalTime()
        val day = local.dayOfWeek.value
        val engine = RuleEngine()

        // 1. Determine primary cause following RuleEngine precedence.
        val appRule = ruleSet.appRules.firstOrNull { it.packageId == packageId }
        val activeRoutines = ruleSet.routines.filter { routine ->
            day in routine.days &&
                engine.inWindow(time, routine.startTime, routine.endTime) &&
                packageId !in routine.allowedApps &&
                (packageId in routine.blockedApps || routine.allowedApps.isNotEmpty())
        }
        val appLimit = if (appRule?.action == "time_limit") effectiveAppLimit(appRule, local) else 0
        val appUsed = minutesUsedToday[packageId] ?: 0
        val appLimitReached = appRule?.action == "time_limit" && appLimit > 0 && appUsed >= appLimit

        val screenTime = ruleSet.screenTime
        val effectiveDailyLimit = effectiveDailyLimit(ruleSet, local, bonusMinutes)
        val totalUsed = minutesUsedToday.values.sum()
        val dailyLimitReached = effectiveDailyLimit > 0 && totalUsed >= effectiveDailyLimit

        val explicitAllow = appRule?.action == "allow"
        val explicitBlock = appRule?.action == "block"
        val defaultProtected = !explicitAllow && (blocklist.containsKey(packageId) || declaresVpnService)

        val bedtimeEnabled = isWindowEnabled(screenTime.bedtimeStart, screenTime.bedtimeEnd)
        val bedtimeActive = !explicitAllow && bedtimeEnabled &&
            engine.inWindow(time, screenTime.bedtimeStart, screenTime.bedtimeEnd)
        val schoolEnabled = screenTime.schoolHours.days.isNotEmpty() &&
            isWindowEnabled(screenTime.schoolHours.start, screenTime.schoolHours.end)
        val schoolActive = !explicitAllow && schoolEnabled &&
            day in screenTime.schoolHours.days &&
            engine.inWindow(time, screenTime.schoolHours.start, screenTime.schoolHours.end)

        val primaryCause: BlockCause
        var routineName: String? = null
        var usedMinutes: Int? = null
        var limitMinutes: Int? = null

        when {
            pausedInternet -> primaryCause = BlockCause.PAUSED_INTERNET
            activeRoutines.isNotEmpty() -> {
                primaryCause = BlockCause.ROUTINE
                routineName = activeRoutines.first().name.takeIf { it.isNotBlank() }
            }
            explicitBlock -> primaryCause = BlockCause.APP_BLOCKED
            appLimitReached -> {
                primaryCause = BlockCause.APP_LIMIT
                usedMinutes = appUsed
                limitMinutes = appLimit
            }
            defaultProtected -> primaryCause = BlockCause.APP_BLOCKED
            dailyLimitReached -> {
                primaryCause = BlockCause.DAILY_LIMIT
                usedMinutes = totalUsed
                limitMinutes = effectiveDailyLimit
            }
            bedtimeActive -> primaryCause = BlockCause.BEDTIME
            schoolActive -> primaryCause = BlockCause.SCHOOL
            else -> return fallbackExplanation(fallbackReason, fallbackWindow, local, stillOpen)
        }

        // 2. Compute "Back again" as the LATER of all active rules, extending across contiguous
        // scheduled windows (e.g. overnight bedtime handing off directly into morning school hours).
        val hasIndefiniteBlock = pausedInternet || explicitBlock || defaultProtected
        val backAt: LocalDateTime? = if (hasIndefiniteBlock) {
            null
        } else {
            val candidates = mutableListOf<LocalDateTime>()
            for (routine in activeRoutines) {
                nextEndDateTime(local, routine.endTime)?.let { candidates += it }
            }
            if (appLimitReached || dailyLimitReached) {
                candidates += local.toLocalDate().plusDays(1).atStartOfDay()
            }
            if (bedtimeActive) {
                nextEndDateTime(local, screenTime.bedtimeEnd)?.let { candidates += it }
            }
            if (schoolActive) {
                nextEndDateTime(local, screenTime.schoolHours.end)?.let { candidates += it }
            }
            candidates.maxOrNull()?.let { initial ->
                extendAcrossContiguousWindows(
                    initial = initial,
                    ruleSet = ruleSet,
                    packageId = packageId,
                    explicitAllow = explicitAllow,
                    bedtimeEnabled = bedtimeEnabled,
                    schoolEnabled = schoolEnabled,
                    engine = engine,
                )
            }
        }

        // 3. G3: offer "Ask for 15 more minutes of screen time" ONLY when daily limit is blocking
        // and no other active rule would still keep the app blocked after a bonus grant.
        val canAskTime = primaryCause == BlockCause.DAILY_LIMIT &&
            !pausedInternet &&
            activeRoutines.isEmpty() &&
            !explicitBlock &&
            !appLimitReached &&
            !defaultProtected &&
            !bedtimeActive &&
            !schoolActive

        // Only show "Back at HH:mm" (today) or "Tomorrow at HH:mm" (tomorrow). A contiguous chain
        // extending past tomorrow omits the card rather than printing the wrong day (Codex #1188 P2).
        val visibleBackAt = backAt?.takeIf { !it.toLocalDate().isAfter(local.toLocalDate().plusDays(1)) }

        return BlockExplanation(
            cause = primaryCause,
            routineName = routineName,
            usedMinutes = usedMinutes,
            limitMinutes = limitMinutes,
            backAtTime = visibleBackAt?.format(HH_MM),
            backAtTomorrow = visibleBackAt != null && visibleBackAt.toLocalDate().isAfter(local.toLocalDate()),
            canAskForMoreTime = canAskTime,
            stillOpenPackages = stillOpen,
        )
    }

    /**
     * Exact G2 request metadata contract confirmed on #1179 (7193395482, 7193558343):
     * - Daily-limit time ask: `requestType = "time"`, `minutes = "15"`, `packageId`, `reason = "daily_limit"`.
     * - All other causes: `requestType = "access"`, `packageId`, `reason` (#1116 compatible).
     */
    fun buildRequestPayload(
        packageId: String,
        explanation: BlockExplanation,
        fallbackReason: String,
        requestedMinutes: Int = 15,
    ): ChildRequestPayload {
        if (explanation.canAskForMoreTime) {
            val mins = if (requestedMinutes in ALLOWED_TIME_REQUEST_MINUTES) requestedMinutes else 15
            return ChildRequestPayload(
                title = "Screen time requested",
                body = "Child asked for $mins more minutes of screen time",
                metadata = mapOf(
                    "requestType" to "time",
                    "minutes" to mins.toString(),
                    "packageId" to packageId,
                    "reason" to "daily_limit",
                ),
            )
        }
        return ChildRequestPayload(
            title = "Access requested",
            body = "Child requested access to $packageId",
            metadata = mapOf(
                "requestType" to "access",
                "packageId" to packageId,
                "reason" to fallbackReason,
            ),
        )
    }

    /** Builds a calm, honest summary for the C-02 "See my rules" sheet. */
    fun rulesSummary(
        ruleSet: RuleSetDto?,
        now: ZonedDateTime,
        minutesUsedToday: Map<String, Int>,
        bonusMinutes: Int,
    ): ChildRulesSummary {
        if (ruleSet == null) {
            return ChildRulesSummary(
                dailyLimitMinutes = null,
                dailyUsedMinutes = minutesUsedToday.values.sum(),
                bedtimeWindow = null,
                schoolWindow = null,
                routineNames = emptyList(),
            )
        }
        val local = now.toLocalDateTime()
        val limit = effectiveDailyLimit(ruleSet, local, bonusMinutes).takeIf { it > 0 }
        val st = ruleSet.screenTime
        val bedtime = if (isWindowEnabled(st.bedtimeStart, st.bedtimeEnd)) {
            st.bedtimeStart.trim() to st.bedtimeEnd.trim()
        } else {
            null
        }
        val school = if (st.schoolHours.days.isNotEmpty() && isWindowEnabled(st.schoolHours.start, st.schoolHours.end)) {
            st.schoolHours.start.trim() to st.schoolHours.end.trim()
        } else {
            null
        }
        return ChildRulesSummary(
            dailyLimitMinutes = limit,
            dailyUsedMinutes = minutesUsedToday.values.sum(),
            bedtimeWindow = bedtime,
            schoolWindow = school,
            routineNames = ruleSet.routines.mapNotNull { it.name.trim().takeIf(String::isNotEmpty) },
        )
    }

    private fun fallbackExplanation(
        fallbackReason: String,
        fallbackWindow: WindowReason?,
        local: LocalDateTime,
        stillOpen: List<String>,
    ): BlockExplanation {
        if (fallbackWindow != null) {
            val backAt = nextEndDateTime(local, fallbackWindow.endsAt)
            val cause = when (fallbackWindow.kind) {
                WindowKind.BEDTIME -> BlockCause.BEDTIME
                WindowKind.SCHOOL -> BlockCause.SCHOOL
                WindowKind.ROUTINE -> BlockCause.ROUTINE
            }
            return BlockExplanation(
                cause = cause,
                routineName = fallbackWindow.name?.takeIf { it.isNotBlank() },
                backAtTime = backAt?.format(HH_MM) ?: fallbackWindow.endsAt.takeIf { it.isNotBlank() },
                backAtTomorrow = backAt != null && backAt.toLocalDate().isAfter(local.toLocalDate()),
                canAskForMoreTime = false,
                stillOpenPackages = stillOpen,
            )
        }
        if (fallbackReason == BlockActivity.REASON_TIME_LIMIT) {
            val resetAt = local.toLocalDate().plusDays(1).atStartOfDay()
            return BlockExplanation(
                cause = BlockCause.DAILY_LIMIT,
                backAtTime = resetAt.format(HH_MM),
                backAtTomorrow = true,
                canAskForMoreTime = true,
                stillOpenPackages = stillOpen,
            )
        }
        return BlockExplanation(
            cause = BlockCause.APP_BLOCKED,
            canAskForMoreTime = false,
            stillOpenPackages = stillOpen,
        )
    }

    private fun effectiveDailyLimit(ruleSet: RuleSetDto, local: LocalDateTime, bonusMinutes: Int): Int {
        val st = ruleSet.screenTime
        if (st.dailyLimitMinutes <= 0) return 0
        val base = if (isWeekend(local) && st.weekendLimitMinutes > 0) {
            st.weekendLimitMinutes
        } else {
            st.dailyLimitMinutes
        }
        return base + bonusMinutes.coerceAtLeast(0)
    }

    private fun effectiveAppLimit(
        appRule: com.familyshield.agent.network.dto.AppRuleDto,
        local: LocalDateTime,
    ): Int = if (isWeekend(local) && appRule.weekendDailyLimitMinutes != null) {
        appRule.weekendDailyLimitMinutes
    } else {
        appRule.dailyLimitMinutes
    }

    private fun isWeekend(t: LocalDateTime): Boolean =
        t.dayOfWeek == DayOfWeek.SATURDAY || t.dayOfWeek == DayOfWeek.SUNDAY

    private fun isWindowEnabled(start: String, end: String): Boolean {
        val s = parseHhMm(start) ?: return false
        val e = parseHhMm(end) ?: return false
        return s != e
    }

    private fun nextEndDateTime(now: LocalDateTime, endHhMm: String): LocalDateTime? {
        val end = parseHhMm(endHhMm) ?: return null
        val todayEnd = now.toLocalDate().atTime(end)
        return if (todayEnd.isAfter(now)) todayEnd else now.toLocalDate().plusDays(1).atTime(end)
    }

    /**
     * Re-evaluates scheduled blockers (routines, bedtime, school hours) at [initial] and advances
     * through any contiguous blocking window so C-02 never promises a return time while another
     * scheduled window still holds the app shut. Returns null if bounded hops cannot clear (24 h cover).
     */
    private fun extendAcrossContiguousWindows(
        initial: LocalDateTime,
        ruleSet: RuleSetDto,
        packageId: String,
        explicitAllow: Boolean,
        bedtimeEnabled: Boolean,
        schoolEnabled: Boolean,
        engine: RuleEngine,
    ): LocalDateTime? {
        var candidate = initial
        val screenTime = ruleSet.screenTime
        repeat(8) {
            val time = candidate.toLocalTime()
            val day = candidate.dayOfWeek.value
            val coveringEnds = mutableListOf<LocalDateTime>()
            for (routine in ruleSet.routines) {
                if (day in routine.days &&
                    engine.inWindow(time, routine.startTime, routine.endTime) &&
                    packageId !in routine.allowedApps &&
                    (packageId in routine.blockedApps || routine.allowedApps.isNotEmpty())
                ) {
                    nextEndDateTime(candidate, routine.endTime)?.let { coveringEnds += it }
                }
            }
            if (!explicitAllow && bedtimeEnabled &&
                engine.inWindow(time, screenTime.bedtimeStart, screenTime.bedtimeEnd)
            ) {
                nextEndDateTime(candidate, screenTime.bedtimeEnd)?.let { coveringEnds += it }
            }
            if (!explicitAllow && schoolEnabled &&
                day in screenTime.schoolHours.days &&
                engine.inWindow(time, screenTime.schoolHours.start, screenTime.schoolHours.end)
            ) {
                nextEndDateTime(candidate, screenTime.schoolHours.end)?.let { coveringEnds += it }
            }
            val next = coveringEnds.maxOrNull() ?: return candidate
            if (!next.isAfter(candidate)) return null
            candidate = next
        }
        return null
    }

    private fun parseHhMm(value: String): LocalTime? =
        runCatching { LocalTime.parse(value.trim()) }.getOrNull()
}
