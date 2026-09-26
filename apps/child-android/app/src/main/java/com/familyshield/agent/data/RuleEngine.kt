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
    ): RuleRepository.Decision {
        val local = now.toLocalDateTime()
        val time = local.toLocalTime()
        val day = local.dayOfWeek.value

        // 0. Always-allowed apps (Feature #9/#11): parent-mandated exemptions win over
        // routines, per-app rules, the blocklist, the global limit, bedtime, school and pause.
        if (packageId in ruleSet.alwaysAllowedApps) return RuleRepository.Decision.ALLOW

        // 1. Pause-the-internet (Feature #11): everything not always-allowed is blocked.
        // NOTE: the test build enforces pause via app blocking here; production routes all
        // traffic through a VpnService sinkhole (see CommandDispatcher.pauseInternet).
        if (pausedInternet) return RuleRepository.Decision.BLOCK

        // 2. Routine windows: blockedApps / allowedApps restricted by day-of-week + time.
        for (routine in ruleSet.routines) {
            if (day !in routine.days) continue
            if (!inWindow(time, routine.startTime, routine.endTime)) continue
            // NOTE: an explicit allow-list membership wins over blockedApps inside the same
            // routine — a contradictory config resolves to the parent's explicit allow.
            if (packageId in routine.allowedApps) continue
            if (packageId in routine.blockedApps) return RuleRepository.Decision.BLOCK
            if (routine.allowedApps.isNotEmpty()) {
                return RuleRepository.Decision.BLOCK
            }
        }

        // 2. App-level rules.
        val appRule = ruleSet.appRules.firstOrNull { it.packageId == packageId }
        if (appRule != null) {
            when (appRule.action) {
                // NOTE: an explicit "allow" short-circuits every later window (parent override).
                "allow" -> return RuleRepository.Decision.ALLOW
                "block" -> return RuleRepository.Decision.BLOCK
                "time_limit" -> {
                    val limit = appRule.effectiveLimit(local)
                    val used = minutesUsedToday[packageId] ?: 0
                    if (limit > 0 && used >= limit) return RuleRepository.Decision.TIME_LIMIT_REACHED
                }
            }
        }

        // 3. Default category protection (Feature #1): an app from the blocklist pack whose
        // category is blocked is blocked. NOTE: ordering — alwaysAllowedApps and an explicit
        // per-app "allow" beat the blocklist; the blocklist in turn beats the global time
        // limit, bedtime and school-hours windows.
        if (blocklist.containsKey(packageId)) return RuleRepository.Decision.BLOCK

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
            if (minutesUsedToday.values.sum() >= limit) return RuleRepository.Decision.TIME_LIMIT_REACHED
        }

        // 5. Bedtime window (applies every day).
        if (inWindow(time, screenTime.bedtimeStart, screenTime.bedtimeEnd)) {
            return RuleRepository.Decision.BLOCK
        }

        // 6. School-hours window (restricted to its configured days).
        if (day in screenTime.schoolHours.days &&
            inWindow(time, screenTime.schoolHours.start, screenTime.schoolHours.end)
        ) {
            return RuleRepository.Decision.BLOCK
        }

        return RuleRepository.Decision.ALLOW
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
