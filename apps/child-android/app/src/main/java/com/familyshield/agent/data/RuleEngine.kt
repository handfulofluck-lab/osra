package com.familyshield.agent.data

import com.familyshield.agent.network.dto.RuleSetDto
import java.time.DayOfWeek
import java.time.LocalDateTime
import java.time.LocalTime
import java.time.ZonedDateTime

/**
 * Pure rule evaluation (no Android classes — runs on the JVM). Applies, in order:
 * always-allowed exemptions, the pause-internet flag, routine windows, per-app rules,
 * the default-category blocklist (Feature #1), the global screen-time limit (plus any
 * bonus minutes granted today), the bedtime window, then the school-hours window.
 * Days are encoded 1=Monday .. 7=Sunday. Window bounds are "HH:mm" local
 * times and may wrap midnight (e.g. bedtime 21:00–07:00).
 */
class RuleEngine {

    /**
     * Returns the [RuleRepository.Decision] for [packageId] at [now] given the minutes already
     * used today per app ([minutesUsedToday], values are whole minutes since local midnight),
     * the merged default-category blocklist ([blocklist], packageId -> blocked category),
     * the pause-internet flag ([pausedInternet], Feature #11) and bonus minutes granted today
     * ([bonusMinutes], Feature #10, added on top of the effective global daily limit).
     */
    fun evaluate(
        ruleSet: RuleSetDto,
        packageId: String,
        now: ZonedDateTime = ZonedDateTime.now(),
        minutesUsedToday: Map<String, Int> = emptyMap(),
        blocklist: Map<String, String> = emptyMap(),
        pausedInternet: Boolean = false,
        bonusMinutes: Int = 0,
    ): RuleRepository.Decision = evaluateWithReason(
        ruleSet,
        packageId,
        now,
        minutesUsedToday,
        blocklist,
        pausedInternet,
        bonusMinutes,
    ).decision

    /**
     * Issue #473: the same walk, answering both questions — the decision **and** the window that fired.
     *
     * `evaluate` is its one-line wrapper, so the order has one home and the reason cannot be computed by a
     * second pass (which is what named a window for a pause and for a blocklisted app in the first
     * version).
     */
    fun evaluateWithReason(
        ruleSet: RuleSetDto,
        packageId: String,
        now: ZonedDateTime = ZonedDateTime.now(),
        minutesUsedToday: Map<String, Int> = emptyMap(),
        blocklist: Map<String, String> = emptyMap(),
        pausedInternet: Boolean = false,
        bonusMinutes: Int = 0,
    ): Verdict {
        val local = now.toLocalDateTime()
        val time = local.toLocalTime()
        val day = local.dayOfWeek.value

        // 0. Always-allowed apps (Feature #9/#11): parent-mandated exemptions win over
        // routines, per-app rules, the blocklist, the global limit, bedtime, school and pause.
        if (packageId in ruleSet.alwaysAllowedApps) return Verdict(RuleRepository.Decision.ALLOW)

        // 1. Pause-the-internet (Feature #11): everything not always-allowed is blocked.
        // NOTE: the test build enforces pause via app blocking here; production routes all
        // traffic through a VpnService sinkhole (see CommandDispatcher.pauseInternet).
        if (pausedInternet) return Verdict(RuleRepository.Decision.BLOCK) // a pause is not a window

        // 2. Routine windows: blockedApps / allowedApps restricted by day-of-week + time.
        // Issue #473: the loop lives in [routineWindow] so the reason it returns and the decision it
        // makes cannot drift apart.
        routineWindow(ruleSet, packageId, local)?.let { return Verdict(RuleRepository.Decision.BLOCK, it) }

        // 2. App-level rules.
        val appRule = ruleSet.appRules.firstOrNull { it.packageId == packageId }
        if (appRule != null) {
            when (appRule.action) {
                // NOTE: an explicit "allow" short-circuits every later window (parent override).
                "allow" -> return Verdict(RuleRepository.Decision.ALLOW)
                "block" -> return Verdict(RuleRepository.Decision.BLOCK) // the app's own reason, not a window
                "time_limit" -> {
                    val limit = appRule.effectiveLimit(local)
                    val used = minutesUsedToday[packageId] ?: 0
                    if (limit > 0 && used >= limit) return Verdict(RuleRepository.Decision.TIME_LIMIT_REACHED)
                }
            }
        }

        // 3. Default category protection (Feature #1): an app from the blocklist pack whose
        // category is blocked is blocked. NOTE: ordering — alwaysAllowedApps and an explicit
        // per-app "allow" beat the blocklist; the blocklist in turn beats the global time
        // limit, bedtime and school-hours windows.
        if (blocklist.containsKey(packageId)) return Verdict(RuleRepository.Decision.BLOCK) // category protection, not a window

        // 4. Global screen-time limit (weekday vs weekend) plus today-only bonus minutes
        // (Feature #10): effectiveLimit = base daily limit + bonus.
        val screenTime = ruleSet.screenTime
        if (screenTime.dailyLimitMinutes > 0) {
            val base = if (isWeekend(local) && screenTime.weekendLimitMinutes > 0) {
                screenTime.weekendLimitMinutes
            } else {
                screenTime.dailyLimitMinutes
            }
            val limit = base + bonusMinutes.coerceAtLeast(0)
            if (minutesUsedToday.values.sum() >= limit) return Verdict(RuleRepository.Decision.TIME_LIMIT_REACHED)
        }

        // 5-6. Bedtime (every day), then school hours (their configured days). Issue #473: both live in
        // [screenTimeWindow], which returns the window so the block screen can name it.
        screenTimeWindow(ruleSet, local)?.let { return Verdict(RuleRepository.Decision.BLOCK, it) }

        return Verdict(RuleRepository.Decision.ALLOW)
    }

    /**
     * Issue #473: the routine window holding [packageId] at [local], or null.
     *
     * The precedence inside one routine is the one `evaluate` has always used: an explicit allow-list
     * membership wins over `blockedApps`, a `blockedApps` entry blocks, and a routine that has an
     * allow-list at all blocks everything it does not name. Extracted rather than copied: `evaluate`
     * calls this, so the decision and the reason cannot disagree.
     */
    private fun routineWindow(ruleSet: RuleSetDto, packageId: String, local: LocalDateTime): WindowReason? {
        val day = local.dayOfWeek.value
        val time = local.toLocalTime()
        for (routine in ruleSet.routines) {
            if (day !in routine.days) continue
            if (!inWindow(time, routine.startTime, routine.endTime)) continue
            if (packageId in routine.allowedApps) continue
            if (packageId in routine.blockedApps) {
                return WindowReason(WindowKind.ROUTINE, routine.name, routine.endTime)
            }
            if (routine.allowedApps.isNotEmpty()) {
                return WindowReason(WindowKind.ROUTINE, routine.name, routine.endTime)
            }
        }
        return null
    }

    /** Issue #473: bedtime (every day), then school hours (their configured days). */
    private fun screenTimeWindow(ruleSet: RuleSetDto, local: LocalDateTime): WindowReason? {
        val screenTime = ruleSet.screenTime
        val time = local.toLocalTime()
        val day = local.dayOfWeek.value
        if (inWindow(time, screenTime.bedtimeStart, screenTime.bedtimeEnd)) {
            return WindowReason(WindowKind.BEDTIME, null, screenTime.bedtimeEnd)
        }
        if (day in screenTime.schoolHours.days &&
            inWindow(time, screenTime.schoolHours.start, screenTime.schoolHours.end)
        ) {
            return WindowReason(WindowKind.SCHOOL, null, screenTime.schoolHours.end)
        }
        return null
    }

    /** Returns true when [time] falls in [[start], [end]); windows wrapping midnight are supported. */
    fun inWindow(time: LocalTime, start: String, end: String): Boolean {
        val s = parseHhMm(start) ?: return false
        val e = parseHhMm(end) ?: return false
        return if (!s.isAfter(e)) {
            !time.isBefore(s) && time.isBefore(e)
        } else {
            !time.isBefore(s) || time.isBefore(e)
        }
    }

    private fun isWeekend(t: LocalDateTime): Boolean =
        t.dayOfWeek == DayOfWeek.SATURDAY || t.dayOfWeek == DayOfWeek.SUNDAY

    private fun parseHhMm(value: String): LocalTime? =
        runCatching { LocalTime.parse(value.trim()) }.getOrNull()

    private fun com.familyshield.agent.network.dto.AppRuleDto.effectiveLimit(local: LocalDateTime): Int {
        val weekend = local.dayOfWeek == DayOfWeek.SATURDAY || local.dayOfWeek == DayOfWeek.SUNDAY
        return if (weekend && weekendDailyLimitMinutes != null) weekendDailyLimitMinutes else dailyLimitMinutes
    }
}
