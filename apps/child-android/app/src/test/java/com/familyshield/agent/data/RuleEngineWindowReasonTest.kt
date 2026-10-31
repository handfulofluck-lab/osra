package com.familyshield.agent.data

import com.familyshield.agent.network.dto.AppRuleDto
import com.familyshield.agent.network.dto.RoutineDto
import com.familyshield.agent.network.dto.RuleSetDto
import com.familyshield.agent.network.dto.SchoolHoursDto
import com.familyshield.agent.network.dto.ScreenTimeRuleDto
import java.time.ZonedDateTime
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

/**
 * Issue #473: the block screen names the window that is holding the app shut, so a child in a Study
 * routine and a child kept out of school hours stop reading the same sentence.
 *
 * `windowFor` is built from the same two helpers `evaluate` now calls (`routineWindow`,
 * `screenTimeWindow`), so this suite and the 30-odd `RuleRepository`/`RuleEngine` rows are two views of
 * one implementation rather than two implementations.
 *
 * Mutant: make `windowFor` return the window for *any* block — drop the `appRules` short-circuit — and
 * [an app with a block rule of its own is not attributed to a window] goes red.
 */
class RuleEngineWindowReasonTest {

    private val engine = RuleEngine()
    private val meet = "com.example.meet"

    /** A Monday at [hour]:[minute], which is inside the default school days. */
    private fun monday(hour: Int, minute: Int = 0): ZonedDateTime =
        ZonedDateTime.of(2026, 11, 2, hour, minute, 0, 0, java.time.ZoneId.of("UTC"))

    private fun rules(
        appRules: List<AppRuleDto> = emptyList(),
        routines: List<RoutineDto> = emptyList(),
        alwaysAllowed: List<String> = emptyList(),
        schoolDays: List<Int> = listOf(1, 2, 3, 4, 5),
    ) = RuleSetDto(
        childId = "child-1",
        screenTime = ScreenTimeRuleDto(
            dailyLimitMinutes = 0, // no global limit: the windows are what this suite is about
            weekendLimitMinutes = 0,
            bedtimeStart = "21:00",
            bedtimeEnd = "07:00",
            schoolHours = SchoolHoursDto(start = "08:00", end = "15:00", days = schoolDays),
        ),
        appRules = appRules,
        routines = routines,
        alwaysAllowedApps = alwaysAllowed,
    )

    @Test
    fun `school hours name the window and when it ends`() {
        assertEquals(
            WindowReason(WindowKind.SCHOOL, null, "15:00"),
            engine.windowFor(rules(), meet, monday(10)),
        )
    }

    @Test
    fun `bedtime names itself and when it ends`() {
        assertEquals(
            WindowReason(WindowKind.BEDTIME, null, "07:00"),
            engine.windowFor(rules(), meet, monday(22)),
        )
    }

    @Test
    fun `a routine names the family's own window`() {
        val homework = RoutineDto(
            id = "r1",
            name = "Homework",
            startTime = "17:00",
            endTime = "19:00",
            days = listOf(1, 2, 3),
            blockedApps = listOf(meet),
            allowedApps = emptyList(),
        )
        assertEquals(
            WindowReason(WindowKind.ROUTINE, "Homework", "19:00"),
            engine.windowFor(rules(routines = listOf(homework)), meet, monday(17, 30)),
        )
    }

    @Test
    fun `a routine with an allow-list names itself for an app it does not allow`() {
        val study = RoutineDto(
            id = "r2",
            name = "Study",
            startTime = "16:00",
            endTime = "18:00",
            days = listOf(1),
            blockedApps = emptyList(),
            allowedApps = listOf("com.example.dictionary"),
        )
        assertEquals(
            WindowReason(WindowKind.ROUTINE, "Study", "18:00"),
            engine.windowFor(rules(routines = listOf(study)), meet, monday(16, 30)),
        )
    }

    @Test
    fun `an app with a block rule of its own is not attributed to a window`() {
        // The block screen says "Blocked"; naming School hours would promise it opens at 15:00, and it
        // does not. Same rule as #474's parent-app sentence, from the other side.
        val blocked = AppRuleDto(packageId = meet, appName = "Meet", action = "block")
        assertNull(engine.windowFor(rules(appRules = listOf(blocked)), meet, monday(10)))
    }

    @Test
    fun `an allowed app is not held by a window at all`() {
        val allowed = AppRuleDto(packageId = meet, appName = "Meet", action = "allow")
        assertNull(engine.windowFor(rules(appRules = listOf(allowed)), meet, monday(10)))
        assertNull(engine.windowFor(rules(alwaysAllowed = listOf(meet)), meet, monday(22)))
    }

    @Test
    fun `a time limit is the app's own reason, not a window`() {
        val limited = AppRuleDto(packageId = meet, appName = "Meet", action = "time_limit", dailyLimitMinutes = 30)
        assertNull(engine.windowFor(rules(appRules = listOf(limited)), meet, monday(10)))
    }

    @Test
    fun `nothing is named outside every window`() {
        assertNull(engine.windowFor(rules(), meet, monday(16, 30)))
    }

    @Test
    fun `school hours only name their configured days`() {
        // Saturday is outside the default school days.
        val saturday = ZonedDateTime.of(2026, 11, 7, 10, 0, 0, 0, java.time.ZoneId.of("UTC"))
        assertNull(engine.windowFor(rules(), meet, saturday))
    }

    @Test
    fun `the decision and the reason are the same implementation, not two`() {
        // Where a reason exists, `evaluate` must answer BLOCK; where it does not, the decision is the
        // app's own. This is the assertion that would catch the helpers drifting during a refactor.
        val school = rules()
        assertEquals(
            RuleRepository.Decision.BLOCK,
            engine.evaluate(school, meet, monday(10)),
        )
        val blocked = AppRuleDto(packageId = meet, appName = "Meet", action = "block")
        val blockedRules = rules(appRules = listOf(blocked))
        assertEquals(RuleRepository.Decision.BLOCK, engine.evaluate(blockedRules, meet, monday(10)))
        assertNull(engine.windowFor(blockedRules, meet, monday(10)))
    }
}
