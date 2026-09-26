package com.familyshield.agent

import com.familyshield.agent.data.RuleEngine
import com.familyshield.agent.data.RuleRepository.Decision
import com.familyshield.agent.network.dto.AppRuleDto
import com.familyshield.agent.network.dto.RuleSetDto
import com.familyshield.agent.network.dto.SchoolHoursDto
import com.familyshield.agent.network.dto.ScreenTimeRuleDto
import java.time.DayOfWeek
import java.time.LocalDate
import java.time.LocalTime
import java.time.ZoneOffset
import java.time.ZonedDateTime
import java.time.temporal.TemporalAdjusters
import org.junit.Assert.assertEquals
import org.junit.Test

/**
 * Pure-JVM tests for pause-internet ordering (Feature #11) and bonus minutes (Feature #10).
 * NOTE: wind_down scheduling (Feature #22) is Android-timed (coroutine + delay in
 * CommandDispatcher) and deliberately not unit-tested — see the NOTE on windDown().
 */
class RuleEnginePauseBonusTest {

    private val engine = RuleEngine()

    /** Huge global limit, bedtime 21:00–07:00, school 09:00–15:00 Mon–Fri. */
    private fun base(alwaysAllowed: List<String> = emptyList()) = RuleSetDto(
        screenTime = ScreenTimeRuleDto(
            dailyLimitMinutes = 10_080,
            weekendLimitMinutes = 10_080,
            bedtimeStart = "21:00",
            bedtimeEnd = "07:00",
            schoolHours = SchoolHoursDto(
                start = "09:00",
                end = "15:00",
                days = listOf(1, 2, 3, 4, 5),
            ),
        ),
        alwaysAllowedApps = alwaysAllowed,
    )

    private fun at(day: DayOfWeek, hour: Int, minute: Int = 0): ZonedDateTime {
        val date = LocalDate.now().with(TemporalAdjusters.nextOrSame(day))
        return ZonedDateTime.of(date, LocalTime.of(hour, minute), ZoneOffset.UTC)
    }

    @Test
    fun `alwaysAllowed app is ALLOWED during pause while others are BLOCKED`() {
        val rs = base(alwaysAllowed = listOf("com.edu.math"))
        val noonSat = at(DayOfWeek.SATURDAY, 12)
        assertEquals(Decision.ALLOW, engine.evaluate(rs, "com.edu.math", noonSat, pausedInternet = true))
        assertEquals(Decision.BLOCK, engine.evaluate(rs, "com.game", noonSat, pausedInternet = true))
    }

    @Test
    fun `alwaysAllowed app is ALLOWED during bedtime and school hours`() {
        val rs = base(alwaysAllowed = listOf("com.edu.math"))
        assertEquals(Decision.ALLOW, engine.evaluate(rs, "com.edu.math", at(DayOfWeek.MONDAY, 22)))
        assertEquals(Decision.BLOCK, engine.evaluate(rs, "com.game", at(DayOfWeek.MONDAY, 22)))
        assertEquals(Decision.ALLOW, engine.evaluate(rs, "com.edu.math", at(DayOfWeek.MONDAY, 10)))
        assertEquals(Decision.BLOCK, engine.evaluate(rs, "com.game", at(DayOfWeek.MONDAY, 10)))
    }

    @Test
    fun `alwaysAllowed beats blocklist and per-app block rules`() {
        val blocklist = mapOf("com.edu.math" to "gaming")
        val rs = base(alwaysAllowed = listOf("com.edu.math")).copy(
            appRules = listOf(AppRuleDto(packageId = "com.edu.math", appName = "Math", action = "block")),
        )
        val noonSat = at(DayOfWeek.SATURDAY, 12)
        assertEquals(Decision.ALLOW, engine.evaluate(rs, "com.edu.math", noonSat, blocklist = blocklist))
        assertEquals(Decision.ALLOW, engine.evaluate(rs, "com.edu.math", noonSat, blocklist = blocklist, pausedInternet = true))
    }

    @Test
    fun `pause blocks even an explicitly allowed per-app rule`() {
        val rs = base().copy(
            appRules = listOf(AppRuleDto(packageId = "com.game", appName = "Game", action = "allow")),
        )
        val noonSat = at(DayOfWeek.SATURDAY, 12)
        assertEquals(Decision.ALLOW, engine.evaluate(rs, "com.game", noonSat))
        assertEquals(Decision.BLOCK, engine.evaluate(rs, "com.game", noonSat, pausedInternet = true))
    }

    @Test
    fun `pause blocks even when the daily limit is not reached`() {
        val rs = base()
        val noonSat = at(DayOfWeek.SATURDAY, 12)
        assertEquals(Decision.ALLOW, engine.evaluate(rs, "com.game", noonSat, pausedInternet = false))
        assertEquals(Decision.BLOCK, engine.evaluate(rs, "com.game", noonSat, pausedInternet = true))
    }

    @Test
    fun `bonus minutes raise the effective daily limit`() {
        val rs = base().copy(
            screenTime = base().screenTime.copy(dailyLimitMinutes = 60, weekendLimitMinutes = 60),
        )
        val noonSat = at(DayOfWeek.SATURDAY, 12)
        val used = mapOf("com.game" to 60)
        // Limit reached without bonus.
        assertEquals(Decision.TIME_LIMIT_REACHED, engine.evaluate(rs, "com.game", noonSat, used))
        // 30 bonus minutes raise the effective limit to 90: 60 used is ALLOWED again.
        assertEquals(Decision.ALLOW, engine.evaluate(rs, "com.game", noonSat, used, bonusMinutes = 30))
        // Boundary: used == limit + bonus still triggers TIME_LIMIT_REACHED (>= semantics).
        assertEquals(
            Decision.TIME_LIMIT_REACHED,
            engine.evaluate(rs, "com.game", noonSat, mapOf("com.game" to 90), bonusMinutes = 30),
        )
        // Bonus never lowers the limit: with no usage it stays ALLOWED.
        assertEquals(Decision.ALLOW, engine.evaluate(rs, "com.game", noonSat, bonusMinutes = 30))
    }
}
