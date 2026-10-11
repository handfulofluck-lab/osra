package com.familyshield.agent

import com.familyshield.agent.data.RuleEngine
import com.familyshield.agent.data.RuleRepository.Decision
import com.familyshield.agent.network.dto.AppRuleDto
import com.familyshield.agent.network.dto.RoutineDto
import com.familyshield.agent.network.dto.RuleSetDto
import com.familyshield.agent.network.dto.ScreenTimeRuleDto
import java.time.DayOfWeek
import java.time.LocalDate
import java.time.LocalTime
import java.time.ZoneOffset
import java.time.ZonedDateTime
import java.time.temporal.TemporalAdjusters
import org.junit.Assert.assertEquals
import org.junit.Test

/** Pure-JVM tests for the rule evaluation core (no Android framework needed). */
class RuleRepositoryTest {

    private val engine = RuleEngine()

    /** Base rule set with a huge global limit and no school days (tests opt in what they need). */
    private fun base() = RuleSetDto(
        screenTime = ScreenTimeRuleDto(
            dailyLimitMinutes = 10_080,
            weekendLimitMinutes = 10_080,
            bedtimeStart = "21:00",
            bedtimeEnd = "07:00",
            schoolHours = com.familyshield.agent.network.dto.SchoolHoursDto(
                start = "09:00",
                end = "15:00",
                days = emptyList(),
            ),
        ),
    )

    private fun at(day: DayOfWeek, hour: Int, minute: Int = 0): ZonedDateTime {
        val date = LocalDate.now().with(TemporalAdjusters.nextOrSame(day))
        return ZonedDateTime.of(date, LocalTime.of(hour, minute), ZoneOffset.UTC)
    }

    @Test
    fun `blocked app returns BLOCK`() {
        val rs = base().copy(
            appRules = listOf(AppRuleDto(packageId = "com.game", appName = "Game", action = "block")),
        )
        assertEquals(Decision.BLOCK, engine.evaluate(rs, "com.game", at(DayOfWeek.SATURDAY, 12)))
    }

    @Test
    fun `time limited app after limit returns TIME_LIMIT_REACHED`() {
        val rs = base().copy(
            appRules = listOf(
                AppRuleDto(packageId = "com.game", appName = "Game", action = "time_limit", dailyLimitMinutes = 30),
            ),
        )
        val saturdayNoon = at(DayOfWeek.SATURDAY, 12)
        assertEquals(
            Decision.TIME_LIMIT_REACHED,
            engine.evaluate(rs, "com.game", saturdayNoon, minutesUsedToday = mapOf("com.game" to 30)),
        )
        assertEquals(
            Decision.ALLOW,
            engine.evaluate(rs, "com.game", saturdayNoon, minutesUsedToday = mapOf("com.game" to 29)),
        )
    }

    @Test
    fun `bedtime window returns BLOCK`() {
        val rs = base()
        assertEquals(Decision.BLOCK, engine.evaluate(rs, "com.anything", at(DayOfWeek.MONDAY, 22)))
        // Window wraps midnight.
        assertEquals(Decision.BLOCK, engine.evaluate(rs, "com.anything", at(DayOfWeek.MONDAY, 6)))
        assertEquals(Decision.ALLOW, engine.evaluate(rs, "com.anything", at(DayOfWeek.MONDAY, 8)))
    }

    @Test
    fun `allowed app returns ALLOW`() {
        val rs = base().copy(
            appRules = listOf(AppRuleDto(packageId = "com.game", appName = "Game", action = "allow")),
        )
        assertEquals(Decision.ALLOW, engine.evaluate(rs, "com.game", at(DayOfWeek.SATURDAY, 12)))
        // No rules at all for another package.
        assertEquals(Decision.ALLOW, engine.evaluate(base(), "com.other", at(DayOfWeek.SATURDAY, 12)))
    }

    @Test
    fun `routine blockedApps window returns BLOCK only in its day and time`() {
        val routine = RoutineDto(
            id = "r1",
            name = "Homework",
            startTime = "15:00",
            endTime = "17:00",
            days = listOf(1), // Monday
            blockedApps = listOf("com.game"),
        )
        val rs = base().copy(routines = listOf(routine))
        assertEquals(Decision.BLOCK, engine.evaluate(rs, "com.game", at(DayOfWeek.MONDAY, 16)))
        assertEquals(Decision.ALLOW, engine.evaluate(rs, "com.game", at(DayOfWeek.TUESDAY, 16)))
        assertEquals(Decision.ALLOW, engine.evaluate(rs, "com.game", at(DayOfWeek.MONDAY, 18)))
    }

    @Test
    fun `weekend limits are honored separately from weekday limits`() {
        val rs = base().copy(
            appRules = listOf(
                AppRuleDto(
                    packageId = "com.game",
                    appName = "Game",
                    action = "time_limit",
                    dailyLimitMinutes = 30,
                    weekendDailyLimitMinutes = 120,
                ),
            ),
        )
        val used = mapOf("com.game" to 60)
        // 60 min blows the 30-min weekday limit but is within the 120-min weekend limit.
        assertEquals(Decision.TIME_LIMIT_REACHED, engine.evaluate(rs, "com.game", at(DayOfWeek.MONDAY, 16), used))
        assertEquals(Decision.ALLOW, engine.evaluate(rs, "com.game", at(DayOfWeek.SATURDAY, 16), used))
    }

    @Test
    fun `isEssentialApp identifies essential system apps and exempts them`() {
        org.junit.Assert.assertTrue(com.familyshield.agent.data.RuleRepository.isEssentialApp("com.familyshield.agent"))
        org.junit.Assert.assertTrue(com.familyshield.agent.data.RuleRepository.isEssentialApp("com.android.systemui"))
        org.junit.Assert.assertTrue(com.familyshield.agent.data.RuleRepository.isEssentialApp("com.android.settings"))
        org.junit.Assert.assertTrue(com.familyshield.agent.data.RuleRepository.isEssentialApp("com.android.dialer"))
        org.junit.Assert.assertTrue(com.familyshield.agent.data.RuleRepository.isEssentialApp("com.google.android.dialer"))
        org.junit.Assert.assertTrue(com.familyshield.agent.data.RuleRepository.isEssentialApp("com.android.launcher3"))
    }

    @Test
    fun `isEssentialApp correctly classifies third-party apps as non-exempt`() {
        org.junit.Assert.assertFalse(com.familyshield.agent.data.RuleRepository.isEssentialApp("com.game"))
        org.junit.Assert.assertFalse(com.familyshield.agent.data.RuleRepository.isEssentialApp("com.instagram.android"))
        org.junit.Assert.assertFalse(com.familyshield.agent.data.RuleRepository.isEssentialApp("com.zhiliaoapp.musically"))
        org.junit.Assert.assertFalse(com.familyshield.agent.data.RuleRepository.isEssentialApp("com.google.android.youtube"))
    }
}
