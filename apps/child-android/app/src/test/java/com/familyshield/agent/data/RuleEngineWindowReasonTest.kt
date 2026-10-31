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
 * `evaluateWithReason` is built from the same two helpers `evaluate` now calls (`routineWindow`,
 * `screenTimeWindow`), so this suite and the 30-odd `RuleRepository`/`RuleEngine` rows are two views of
 * one implementation rather than two implementations — `evaluate` is its one-line wrapper.
 *
 * Mutant: answer a window for *any* block — drop the early returns that name a pause or a blocklisted app
 * as reasonless — and [a pause blocks with no reason, even at bedtime] goes red.
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


    private fun reasonOf(rules: RuleSetDto, pkg: String, at: ZonedDateTime): WindowReason? =
        engine.evaluateWithReason(rules, pkg, at).reason

    @Test
    fun `school hours name the window and when it ends`() {
        assertEquals(
            WindowReason(WindowKind.SCHOOL, null, "15:00"),
            reasonOf(rules(), meet, monday(10)),
        )
    }

    @Test
    fun `bedtime names itself and when it ends`() {
        assertEquals(
            WindowReason(WindowKind.BEDTIME, null, "07:00"),
            reasonOf(rules(), meet, monday(22)),
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
            reasonOf(rules(routines = listOf(homework)), meet, monday(17, 30)),
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
            reasonOf(rules(routines = listOf(study)), meet, monday(16, 30)),
        )
    }

    @Test
    fun `an app with a block rule of its own is not attributed to a window`() {
        // The block screen says "Blocked"; naming School hours would promise it opens at 15:00, and it
        // does not. Same rule as #474's parent-app sentence, from the other side.
        val blocked = AppRuleDto(packageId = meet, appName = "Meet", action = "block")
        assertNull(reasonOf(rules(appRules = listOf(blocked)), meet, monday(10)))
    }

    @Test
    fun `an allowed app is not held by a window at all`() {
        val allowed = AppRuleDto(packageId = meet, appName = "Meet", action = "allow")
        assertNull(reasonOf(rules(appRules = listOf(allowed)), meet, monday(10)))
        assertNull(reasonOf(rules(alwaysAllowed = listOf(meet)), meet, monday(22)))
    }

    @Test
    fun `a time limit that has been reached is the app's own reason, not a window`() {
        val limited = AppRuleDto(packageId = meet, appName = "Meet", action = "time_limit", dailyLimitMinutes = 30)
        val verdict = engine.evaluateWithReason(
            rules(appRules = listOf(limited)),
            meet,
            monday(10),
            minutesUsedToday = mapOf(meet to 30),
        )
        assertEquals(RuleRepository.Decision.TIME_LIMIT_REACHED, verdict.decision)
        assertNull(verdict.reason)
    }

    @Test
    fun `a time-limited app under its limit is held by whatever window is in force`() {
        // #496 review found the first version suppressed the reason for *any* app rule. It should not: an
        // app allowed 30 minutes a day, blocked at 10:00 with none used, is blocked by school hours, and
        // naming the window is the truth.
        val limited = AppRuleDto(packageId = meet, appName = "Meet", action = "time_limit", dailyLimitMinutes = 30)
        assertEquals(
            WindowReason(WindowKind.SCHOOL, null, "15:00"),
            reasonOf(rules(appRules = listOf(limited)), meet, monday(10)),
        )
    }

    @Test
    fun `nothing is named outside every window`() {
        assertNull(reasonOf(rules(), meet, monday(16, 30)))
    }

    @Test
    fun `school hours only name their configured days`() {
        // Saturday is outside the default school days.
        val saturday = ZonedDateTime.of(2026, 11, 7, 10, 0, 0, 0, java.time.ZoneId.of("UTC"))
        assertNull(reasonOf(rules(), meet, saturday))
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
        assertNull(reasonOf(blockedRules, meet, monday(10)))
    }

    @Test
    fun `a pause blocks with no reason, even at bedtime (#496 review)`() {
        // The pause is step 1; the window is step 5. Naming Bedtime here would be a window the decision
        // never reached — the first version's bug.
        val verdict = engine.evaluateWithReason(rules(), meet, monday(22), pausedInternet = true)
        assertEquals(RuleRepository.Decision.BLOCK, verdict.decision)
        assertNull(verdict.reason)
    }

    @Test
    fun `a blocklisted app blocks with no reason, even during school hours (#496 review)`() {
        val verdict = engine.evaluateWithReason(
            rules(),
            meet,
            monday(10),
            blocklist = mapOf(meet to "gaming"),
        )
        assertEquals(RuleRepository.Decision.BLOCK, verdict.decision)
        assertNull(verdict.reason)
    }

    @Test
    fun `a routine beats bedtime, because step 2 is read first (#496 review)`() {
        val homework = RoutineDto(
            id = "r1",
            name = "Homework",
            startTime = "20:00",
            endTime = "23:00",
            days = listOf(1),
            blockedApps = listOf(meet),
            allowedApps = emptyList(),
        )
        // 22:00 is inside bedtime (21:00-07:00) *and* inside Homework: the routine is the reason.
        assertEquals(
            WindowReason(WindowKind.ROUTINE, "Homework", "23:00"),
            reasonOf(rules(routines = listOf(homework)), meet, monday(22)),
        )
    }

    @Test
    fun `the wrapper never changes a decision (#496 review)`() {
        // The parity row: every case above, through both entry points.
        val cases = listOf(
            Triple(rules(), meet, monday(10)),
            Triple(rules(), meet, monday(22)),
            Triple(rules(), meet, monday(16, 30)),
            Triple(
                rules(appRules = listOf(AppRuleDto(packageId = meet, appName = "Meet", action = "block"))),
                meet,
                monday(10),
            ),
            Triple(rules(alwaysAllowed = listOf(meet)), meet, monday(10)),
        )
        for ((ruleSet, pkg, at) in cases) {
            assertEquals(
                engine.evaluate(ruleSet, pkg, at),
                engine.evaluateWithReason(ruleSet, pkg, at).decision,
            )
        }
    }
}
