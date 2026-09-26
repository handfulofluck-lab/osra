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

/** Pure-JVM tests for default-category blocklist enforcement in the rule engine (Feature #1). */
class RuleEngineBlocklistTest {

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

    @Test
    fun `blocklisted app with blocked category returns BLOCK`() {
        val blocklist = mapOf("com.example.bet" to "gambling")
        // 12:00 Saturday: no routine, no app rule, global limit huge, outside bedtime/school.
        assertEquals(
            Decision.BLOCK,
            engine.evaluate(base(), "com.example.bet", at(DayOfWeek.SATURDAY, 12), blocklist = blocklist),
        )
    }

    @Test
    fun `app not on the blocklist is unaffected by the blocklist`() {
        val blocklist = mapOf("com.example.bet" to "gambling")
        assertEquals(
            Decision.ALLOW,
            engine.evaluate(base(), "com.other", at(DayOfWeek.SATURDAY, 12), blocklist = blocklist),
        )
    }

    @Test
    fun `blocklist beats bedtime but an explicit allow beats the blocklist`() {
        val blocklist = mapOf("com.example.bet" to "gambling")
        // 22:00 would be BLOCK via bedtime anyway; blocklist must not weaken any existing block.
        assertEquals(
            Decision.BLOCK,
            engine.evaluate(base(), "com.example.bet", at(DayOfWeek.MONDAY, 22), blocklist = blocklist),
        )
        val rs = base().copy(
            appRules = listOf(AppRuleDto(packageId = "com.example.bet", appName = "Bet", action = "allow")),
        )
        // The explicit per-app allow is evaluated before the blocklist and wins.
        assertEquals(
            Decision.ALLOW,
            engine.evaluate(rs, "com.example.bet", at(DayOfWeek.SATURDAY, 12), blocklist = blocklist),
        )
    }

    @Test
    fun `blocklist beats global time limit`() {
        val rs = base().copy(
            screenTime = base().screenTime.copy(dailyLimitMinutes = 60, weekendLimitMinutes = 60),
        )
        val used = mapOf("com.example.bet" to 60)
        val blocklist = mapOf("com.example.bet" to "gambling")
        assertEquals(
            Decision.BLOCK,
            engine.evaluate(rs, "com.example.bet", at(DayOfWeek.SATURDAY, 12), used, blocklist),
        )
    }
}
