package com.familyshield.agent.data

import com.familyshield.agent.network.dto.RuleSetDto
import java.time.DayOfWeek
import java.time.LocalDateTime
import java.time.LocalTime
import java.time.ZonedDateTime

/**
 * Pure rule evaluation (no Android classes — runs on the JVM). Applies, in order:
 * always-allowed exemptions, routine windows, per-app rules,
 * default VPN app protection and the category blocklist, the global screen-time limit (plus any
 * bonus minutes granted today), the bedtime window, then the school-hours window.
 * Issue #1183: pause-the-internet is enforced at the network layer (VPN sinkhole) only and does
 * not block offline app launches here.
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
     * [declaresVpnService] supplies the current installed package classification when a default rule applies.
     */
    fun evaluate(
        ruleSet: RuleSetDto,
        packageId: String,
        now: ZonedDateTime = ZonedDateTime.now(),
        minutesUsedToday: Map<String, Int> = emptyMap(),
        blocklist: Map<String, String> = emptyMap(),
        pausedInternet: Boolean = false,
        bonusMinutes: Int = 0,
        declaresVpnService: () -> Boolean = { false },
    ): RuleRepository.Decision = evaluateWithReason(
        ruleSet,
        packageId,
        now,
        minutesUsedToday,
        blocklist,
        pausedInternet,
        bonusMinutes,
        declaresVpnService,
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
        declaresVpnService: () -> Boolean = { false },
    ): Verdict {
        val local = now.toLocalDateTime()
        val time = local.toLocalTime()
        val day = local.dayOfWeek.value

        // 0. Always-allowed apps (Feature #9/#11): parent-mandated exemptions win over
        // routines, per-app rules, the blocklist, the global limit, bedtime and school.
        if (packageId in ruleSet.alwaysAllowedApps) return Verdict(RuleRepository.Decision.ALLOW)

        // Issue #1183: pause-the-internet is network-only (FilterVpnService MODE_SINKHOLE_ALL), so
        // `pausedInternet` deliberately does not block app launches here — offline apps stay open
        // while normal routine, per-app, blocklist, limit, bedtime and school rules still apply.
        @Suppress("UNUSED_EXPRESSION")
        pausedInternet

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

        // 3. Apply the category blocklist and VPN app protection after explicit parent allowances.
        // These defaults take precedence over the global time limit, bedtime and school hours.
        if (blocklist.containsKey(packageId) || declaresVpnService()) return Verdict(RuleRepository.Decision.BLOCK)

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
            val countableMinutes = com.familyshield.agent.enforcement.EssentialPackages.sumDailyBudgetMinutes(minutesUsedToday)
            if (countableMinutes >= limit) return Verdict(RuleRepository.Decision.TIME_LIMIT_REACHED)
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
