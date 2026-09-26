package com.familyshield.agent

import com.familyshield.agent.data.RuleEngine
import com.familyshield.agent.data.RuleRepository.Decision
import com.familyshield.agent.network.dto.AppRuleDto
import com.familyshield.agent.network.dto.RoutineDto
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

/** Edge-case tests for the rule engine's time windows and priority order (pure JVM). */
class RuleEngineEdgeCasesTest {

    private val engine = RuleEngine()

    /** Same base as RuleRepositoryTest: huge global limit, bedtime 21:00–07:00, no school days. */
    private fun base() = RuleSetDto(
        screenTime = ScreenTimeRuleDto(
            dailyLimitMinutes = 10_080,
            weekendLimitMinutes = 10_080,
            bedtimeStart = "21:00",
            bedtimeEnd = "07:00",
            schoolHours = SchoolHoursDto(start = "09:00", end = "15:00", days = emptyList()),
        ),
    )

    private fun at(day: DayOfWeek, hour: Int, minute: Int = 0): ZonedDateTime {
        val date = LocalDate.now().with(TemporalAdjusters.nextOrSame(day))
        return ZonedDateTime.of(date, LocalTime.of(hour, minute), ZoneOffset.UTC)
    }

    private fun allWeek() = listOf(1, 2, 3, 4, 5, 6, 7)

    @Test
    fun `routine window wrapping midnight blocks on both sides of midnight`() {
        val routine = RoutineDto(
            id = "r1",
            name = "Night",
            startTime = "22:00",
            endTime = "09:00",
            days = listOf(1), // Monday
            blockedApps = listOf("com.game"),
        )
        val rs = base().copy(routines = listOf(routine))
        assertEquals(Decision.BLOCK, engine.evaluate(rs, "com.game", at(DayOfWeek.MONDAY, 23)))
        // 08:00 is past bedtime (ends 07:00), so only the wrap side of the routine can block.
        assertEquals(Decision.BLOCK, engine.evaluate(rs, "com.game", at(DayOfWeek.MONDAY, 8)))
        assertEquals(Decision.ALLOW, engine.evaluate(rs, "com.game", at(DayOfWeek.MONDAY, 20)))
        assertEquals(Decision.ALLOW, engine.evaluate(rs, "com.game", at(DayOfWeek.MONDAY, 9))) // end exclusive
        // NOTE: day gating uses the current day — the Tuesday-early-morning tail of a Monday
        // window does not apply (documented simplest interpretation).
        assertEquals(Decision.ALLOW, engine.evaluate(rs, "com.game", at(DayOfWeek.TUESDAY, 8)))
    }

    @Test
    fun `allowedApps membership beats blockedApps inside the same routine`() {
        val routine = RoutineDto(
            id = "r1",
            name = "Contradictory",
            startTime = "00:00",
            endTime = "23:59",
            days = allWeek(),
            blockedApps = listOf("com.game"),
            allowedApps = listOf("com.game"),
        )
        val rs = base().copy(routines = listOf(routine))
        // 12:00 is outside bedtime; only the routine could block.
        assertEquals(Decision.ALLOW, engine.evaluate(rs, "com.game", at(DayOfWeek.MONDAY, 12)))
    }

    @Test
    fun `routine whitelist blocks non-members and allows members`() {
        val routine = RoutineDto(
            id = "r1",
            name = "Focus",
            startTime = "08:00",
            endTime = "12:00",
            days = allWeek(),
            allowedApps = listOf("com.school"),
        )
        val rs = base().copy(routines = listOf(routine))
        assertEquals(Decision.BLOCK, engine.evaluate(rs, "com.game", at(DayOfWeek.MONDAY, 10)))
        assertEquals(Decision.ALLOW, engine.evaluate(rs, "com.school", at(DayOfWeek.MONDAY, 10)))
        assertEquals(Decision.ALLOW, engine.evaluate(rs, "com.game", at(DayOfWeek.MONDAY, 13)))
    }

    @Test
    fun `school hours apply only on configured weekdays`() {
        val rs = base().copy(
            screenTime = base().screenTime.copy(
                schoolHours = SchoolHoursDto(start = "08:00", end = "15:00", days = listOf(1, 2, 3, 4, 5)),
            ),
        )
        assertEquals(Decision.BLOCK, engine.evaluate(rs, "com.any", at(DayOfWeek.MONDAY, 10)))
        assertEquals(Decision.BLOCK, engine.evaluate(rs, "com.any", at(DayOfWeek.FRIDAY, 10)))
        // Weekends are not in days=[1..5].
        assertEquals(Decision.ALLOW, engine.evaluate(rs, "com.any", at(DayOfWeek.SATURDAY, 10)))
        assertEquals(Decision.ALLOW, engine.evaluate(rs, "com.any", at(DayOfWeek.SUNDAY, 10)))
        // Window bounds: start inclusive, end exclusive.
        assertEquals(Decision.BLOCK, engine.evaluate(rs, "com.any", at(DayOfWeek.MONDAY, 8)))
        assertEquals(Decision.ALLOW, engine.evaluate(rs, "com.any", at(DayOfWeek.MONDAY, 15)))
    }

    @Test
    fun `routine block wins over app-level allow during overlapping bedtime`() {
        val rs = base().copy(
            routines = listOf(
                RoutineDto(
                    id = "r1",
                    name = "Evening",
                    startTime = "20:00",
                    endTime = "23:00",
                    days = allWeek(),
                    blockedApps = listOf("com.game"),
                ),
            ),
            appRules = listOf(AppRuleDto(packageId = "com.game", appName = "Game", action = "allow")),
        )
        // 22:00 is inside both the routine and bedtime; routines are evaluated first.
        assertEquals(Decision.BLOCK, engine.evaluate(rs, "com.game", at(DayOfWeek.MONDAY, 22)))
    }

    @Test
    fun `app-level allow overrides bedtime (documented parent override)`() {
        val rs = base().copy(
            appRules = listOf(AppRuleDto(packageId = "com.game", appName = "Game", action = "allow")),
        )
        assertEquals(Decision.ALLOW, engine.evaluate(rs, "com.game", at(DayOfWeek.MONDAY, 22)))
        // An app without an explicit allow is still blocked by bedtime.
        assertEquals(Decision.BLOCK, engine.evaluate(rs, "com.other", at(DayOfWeek.MONDAY, 22)))
    }

    @Test
    fun `routine-allowed app is still subject to bedtime`() {
        val rs = base().copy(
            routines = listOf(
                RoutineDto(
                    id = "r1",
                    name = "Evening",
                    startTime = "20:00",
                    endTime = "23:00",
                    days = allWeek(),
                    allowedApps = listOf("com.game"),
                ),
            ),
        )
        // The routine exempts com.game from its own blocking, but bedtime still applies.
        assertEquals(Decision.BLOCK, engine.evaluate(rs, "com.game", at(DayOfWeek.MONDAY, 22)))
    }

    @Test
    fun `time limit zero means unlimited`() {
        val rs = base().copy(
            appRules = listOf(
                AppRuleDto(packageId = "com.game", appName = "Game", action = "time_limit", dailyLimitMinutes = 0),
            ),
        )
        assertEquals(
            Decision.ALLOW,
            engine.evaluate(rs, "com.game", at(DayOfWeek.MONDAY, 12), mapOf("com.game" to 10_000)),
        )
    }

    @Test
    fun `time limit boundary is exactly at the limit`() {
        val rs = base().copy(
            appRules = listOf(
                AppRuleDto(packageId = "com.game", appName = "Game", action = "time_limit", dailyLimitMinutes = 45),
            ),
        )
        val noon = at(DayOfWeek.MONDAY, 12)
        assertEquals(Decision.ALLOW, engine.evaluate(rs, "com.game", noon, mapOf("com.game" to 44)))
        assertEquals(Decision.TIME_LIMIT_REACHED, engine.evaluate(rs, "com.game", noon, mapOf("com.game" to 45)))
        assertEquals(Decision.TIME_LIMIT_REACHED, engine.evaluate(rs, "com.game", noon, mapOf("com.game" to 46)))
    }

    @Test
    fun `missing weekend override falls back to the weekday per-app limit`() {
        val rs = base().copy(
            appRules = listOf(
                AppRuleDto(
                    packageId = "com.game",
                    appName = "Game",
                    action = "time_limit",
                    dailyLimitMinutes = 30,
                    weekendDailyLimitMinutes = null,
                ),
            ),
        )
        assertEquals(
            Decision.TIME_LIMIT_REACHED,
            engine.evaluate(rs, "com.game", at(DayOfWeek.SATURDAY, 12), mapOf("com.game" to 30)),
        )
    }

    @Test
    fun `unknown package defaults to ALLOW but is still covered by school hours`() {
        val rs = base().copy(
            screenTime = base().screenTime.copy(
                schoolHours = SchoolHoursDto(start = "08:00", end = "15:00", days = listOf(1, 2, 3, 4, 5)),
            ),
        )
        // No app rule and no routine mentions this package.
        assertEquals(Decision.ALLOW, engine.evaluate(rs, "com.unknown", at(DayOfWeek.MONDAY, 18)))
        assertEquals(Decision.ALLOW, engine.evaluate(rs, "com.unknown", at(DayOfWeek.SATURDAY, 10)))
        // School hours are device-wide: unknown packages are blocked too.
        assertEquals(Decision.BLOCK, engine.evaluate(rs, "com.unknown", at(DayOfWeek.MONDAY, 10)))
    }

    @Test
    fun `weekend global limit replaces the weekday global limit`() {
        val rs = base().copy(
            screenTime = base().screenTime.copy(dailyLimitMinutes = 60, weekendLimitMinutes = 120),
        )
        val used = mapOf("com.a" to 100)
        assertEquals(Decision.TIME_LIMIT_REACHED, engine.evaluate(rs, "com.a", at(DayOfWeek.MONDAY, 12), used))
        assertEquals(Decision.ALLOW, engine.evaluate(rs, "com.a", at(DayOfWeek.SATURDAY, 12), used))
    }

    @Test
    fun `weekend global limit of zero falls back to the daily limit`() {
        val rs = base().copy(
            screenTime = base().screenTime.copy(dailyLimitMinutes = 60, weekendLimitMinutes = 0),
        )
        val used = mapOf("com.a" to 100)
        assertEquals(Decision.TIME_LIMIT_REACHED, engine.evaluate(rs, "com.a", at(DayOfWeek.SATURDAY, 12), used))
    }

    @Test
    fun `global limit sums usage across all apps`() {
        val rs = base().copy(
            screenTime = base().screenTime.copy(dailyLimitMinutes = 60, weekendLimitMinutes = 60),
        )
        val used = mapOf("com.a" to 30, "com.b" to 30)
        assertEquals(Decision.TIME_LIMIT_REACHED, engine.evaluate(rs, "com.c", at(DayOfWeek.MONDAY, 12), used))
    }

    @Test
    fun `bedtime bounds are start-inclusive and end-exclusive`() {
        val rs = base()
        assertEquals(Decision.BLOCK, engine.evaluate(rs, "com.any", at(DayOfWeek.MONDAY, 21, 0)))
        assertEquals(Decision.BLOCK, engine.evaluate(rs, "com.any", at(DayOfWeek.MONDAY, 6, 59)))
        assertEquals(Decision.ALLOW, engine.evaluate(rs, "com.any", at(DayOfWeek.MONDAY, 7, 0)))
    }

    @Test
    fun `malformed window strings disable the window without crashing`() {
        val rs = base().copy(
            routines = listOf(
                RoutineDto(
                    id = "r1",
                    name = "Broken",
                    startTime = "25:99",
                    endTime = "17:00",
                    days = allWeek(),
                    blockedApps = listOf("com.game"),
                ),
            ),
            screenTime = base().screenTime.copy(bedtimeStart = "not-a-time", bedtimeEnd = ""),
        )
        assertEquals(Decision.ALLOW, engine.evaluate(rs, "com.game", at(DayOfWeek.MONDAY, 12)))
        assertEquals(Decision.ALLOW, engine.evaluate(rs, "com.any", at(DayOfWeek.MONDAY, 22)))
    }
}
