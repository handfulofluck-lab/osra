package com.familyshield.agent.network.dto

/**
 * Moshi models mirroring packages/shared-types RuleSet. Pure Kotlin (no Android classes) so the
 * rule engine and unit tests run on the JVM. Days are encoded 1=Monday .. 7=Sunday (ISO-8601).
 */
data class RuleSetDto(
    val id: String = "",
    val childId: String = "",
    val screenTime: ScreenTimeRuleDto = ScreenTimeRuleDto(),
    val webFilter: WebFilterRuleDto = WebFilterRuleDto(),
    val appRules: List<AppRuleDto> = emptyList(),
    val routines: List<RoutineDto> = emptyList(),
    /** Parent-mandated exemptions (Feature #9/#11); beat blocklist, bedtime, school, pause. */
    val alwaysAllowedApps: List<String> = emptyList(),
    /**
     * Feature #2: per-app social-monitoring opt-out keyed by app key (whatsapp, instagram, ...);
     * an absent key means monitoring is ENABLED (default true).
     */
    val socialMonitoring: Map<String, Boolean> = emptyMap(),
    /**
     * Feature #27: parent-curated known contacts (phone numbers, any format). An EMPTY list means
     * unknown-contact alerting is disabled (no alerts raised).
     */
    val contactAllowlist: List<String> = emptyList(),
    val updatedAt: String = "",
)

/** Screen-time limits; window strings are "HH:mm" local time and may wrap midnight. */
data class ScreenTimeRuleDto(
    val dailyLimitMinutes: Int = 0,
    val weekendLimitMinutes: Int = 0,
    val bedtimeStart: String = "21:00",
    val bedtimeEnd: String = "07:00",
    val schoolHours: SchoolHoursDto = SchoolHoursDto(),
)

/** School-hours window; [days] uses 1=Monday .. 7=Sunday. */
data class SchoolHoursDto(
    val start: String = "08:00",
    val end: String = "15:00",
    val days: List<Int> = emptyList(),
)

/** Web filter configuration (enforced by the desktop/proxy agents; carried for completeness). */
data class WebFilterRuleDto(
    val blockedCategories: List<String> = emptyList(),
    val allowedDomains: List<String> = emptyList(),
    val blockedDomains: List<String> = emptyList(),
    val safeSearchEnforced: Boolean = false,
)

/**
 * Per-app rule. [action] is one of "allow" | "block" | "time_limit".
 * NOTE: [weekendDailyLimitMinutes] is an agent-side extension (shared-types AppRule has no
 * per-app weekend limit yet); when null the weekday [dailyLimitMinutes] applies all week.
 */
data class AppRuleDto(
    val packageId: String = "",
    val appName: String = "",
    val action: String = "allow",
    val dailyLimitMinutes: Int = 0,
    val weekendDailyLimitMinutes: Int? = null,
)

/** A named daily window; [days] uses 1=Monday .. 7=Sunday. */
data class RoutineDto(
    val id: String = "",
    val name: String = "",
    val startTime: String = "",
    val endTime: String = "",
    val days: List<Int> = emptyList(),
    val blockedApps: List<String> = emptyList(),
    val allowedApps: List<String> = emptyList(),
)
