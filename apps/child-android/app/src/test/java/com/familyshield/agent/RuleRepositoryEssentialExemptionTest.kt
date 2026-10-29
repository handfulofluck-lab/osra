package com.familyshield.agent

import com.familyshield.agent.data.RuleEngine
import com.familyshield.agent.data.RuleRepository
import com.familyshield.agent.data.RuleRepository.Decision
import com.familyshield.agent.enforcement.EssentialPackages
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

/**
 * Issue #165: a block rule must never be answered for the launcher, the system UI or the call
 * surfaces — and every *other* app must still be blocked by the same rule. Each test drives one policy
 * that can raise `BlockActivity` through the real [RuleEngine] and the real
 * [RuleRepository.decide] gate, so the exemption is pinned where production applies it.
 *
 * Before the fix the gate only existed on the empty-cache path, so every `bedtime`, `routine`,
 * `pause`, `blocklist` and `screen-time` case below answered BLOCK for the launcher.
 */
class RuleRepositoryEssentialExemptionTest {

    private val engine = RuleEngine()

    private val launcher = "com.sec.android.app.launcher"
    private val systemUi = "com.android.systemui"
    private val dialer = "com.samsung.android.dialer"
    private val emergency = "com.samsung.android.emergency"
    private val thirdParty = "com.game"

    private val essentials = listOf(launcher, systemUi, dialer, emergency)

    private fun at(day: DayOfWeek, hour: Int): ZonedDateTime {
        val date = LocalDate.of(2026, 10, 19).with(TemporalAdjusters.nextOrSame(day))
        return ZonedDateTime.of(date, LocalTime.of(hour, 0), ZoneOffset.UTC)
    }

    /** Exactly what [RuleRepository.evaluate] does, minus the Android-backed sources. */
    private fun decide(
        pkg: String,
        rules: RuleSetDto?,
        now: ZonedDateTime = at(DayOfWeek.MONDAY, 12),
        used: Map<String, Int> = emptyMap(),
        blocklist: Map<String, String> = emptyMap(),
        pausedInternet: Boolean = false,
        bonusMinutes: Int = 0,
        paired: Boolean = true,
        consentPaused: Boolean = false,
    ): Decision = RuleRepository.decide(pkg, rules, paired, consentPaused) { active ->
        engine.evaluate(active, pkg, now, used, blocklist, pausedInternet, bonusMinutes)
    }

    /** The no-limit baseline; bedtime is the default 21:00–07:00 window. */
    private fun rules() = RuleSetDto(
        screenTime = ScreenTimeRuleDto(
            dailyLimitMinutes = 10_080,
            weekendLimitMinutes = 10_080,
            bedtimeStart = "21:00",
            bedtimeEnd = "07:00",
            schoolHours = SchoolHoursDto(days = emptyList()),
        ),
    )

    private fun assertOnlyEssentialsExempt(blocked: Decision, rules: RuleSetDto?, now: ZonedDateTime) {
        for (pkg in essentials) {
            assertEquals("$pkg must never be covered", Decision.ALLOW, decide(pkg, rules, now))
        }
        assertEquals("the rule must still block a third-party app", blocked, decide(thirdParty, rules, now))
    }

    @Test
    fun `an empty cache fails closed for apps and never for the launcher`() {
        assertOnlyEssentialsExempt(Decision.BLOCK, rules = null, now = at(DayOfWeek.MONDAY, 22))
        // Unpaired is still "no enforcement at all", unchanged.
        for (pkg in essentials + thirdParty) {
            assertEquals(pkg, Decision.ALLOW, decide(pkg, null, paired = false))
        }
    }

    @Test
    fun `bedtime never covers the launcher, the system UI or the dialer`() {
        assertOnlyEssentialsExempt(Decision.BLOCK, rules(), at(DayOfWeek.MONDAY, 22))
        // The window wraps midnight.
        assertOnlyEssentialsExempt(Decision.BLOCK, rules(), at(DayOfWeek.MONDAY, 6))
        // Outside the window nothing is blocked — the exemption is not a blanket allow.
        assertEquals(Decision.ALLOW, decide(thirdParty, rules(), at(DayOfWeek.MONDAY, 12)))
    }

    @Test
    fun `an allow-list routine blocks third-party apps but not the essential set`() {
        val rs = rules().copy(
            routines = listOf(
                RoutineDto(
                    id = "r1",
                    name = "Homework",
                    startTime = "15:00",
                    endTime = "17:00",
                    days = listOf(1),
                    allowedApps = listOf("com.allowed"),
                ),
            ),
        )
        assertOnlyEssentialsExempt(Decision.BLOCK, rs, at(DayOfWeek.MONDAY, 16))
        assertEquals(Decision.ALLOW, decide("com.allowed", rs, at(DayOfWeek.MONDAY, 16)))
    }

    @Test
    fun `a routine blockedApps window blocks its own apps only`() {
        val rs = rules().copy(
            routines = listOf(
                RoutineDto(
                    id = "r1",
                    name = "Homework",
                    startTime = "15:00",
                    endTime = "17:00",
                    days = listOf(1),
                    blockedApps = listOf(thirdParty, launcher),
                ),
            ),
        )
        // The launcher is named explicitly and still stays reachable: it is the home screen.
        assertOnlyEssentialsExempt(Decision.BLOCK, rs, at(DayOfWeek.MONDAY, 16))
    }

    @Test
    fun `pause the internet blocks third-party apps but not the essential set`() {
        for (pkg in essentials) {
            assertEquals(pkg, Decision.ALLOW, decide(pkg, rules(), at(DayOfWeek.MONDAY, 12), pausedInternet = true))
        }
        assertEquals(Decision.BLOCK, decide(thirdParty, rules(), at(DayOfWeek.MONDAY, 12), pausedInternet = true))
    }

    @Test
    fun `the default-category blocklist cannot cover the essential set`() {
        val blocklist = mapOf(thirdParty to "games", launcher to "games", systemUi to "games")
        for (pkg in essentials) {
            assertEquals(pkg, Decision.ALLOW, decide(pkg, rules(), at(DayOfWeek.MONDAY, 12), blocklist = blocklist))
        }
        assertEquals(Decision.BLOCK, decide(thirdParty, rules(), at(DayOfWeek.MONDAY, 12), blocklist = blocklist))
    }

    @Test
    fun `a global screen-time limit cannot cover the essential set`() {
        val rs = rules().copy(screenTime = rules().screenTime.copy(dailyLimitMinutes = 30))
        val used = mapOf(thirdParty to 30)
        for (pkg in essentials) {
            assertEquals(pkg, Decision.ALLOW, decide(pkg, rs, at(DayOfWeek.MONDAY, 12), used = used))
        }
        assertEquals(Decision.TIME_LIMIT_REACHED, decide(thirdParty, rs, at(DayOfWeek.MONDAY, 12), used = used))
    }

    @Test
    fun `an app-level block or time limit on the dialer is still exempt`() {
        val rs = rules().copy(
            appRules = listOf(
                AppRuleDto(packageId = dialer, appName = "Phone", action = "block"),
                AppRuleDto(packageId = thirdParty, appName = "Game", action = "block"),
            ),
        )
        assertEquals(Decision.ALLOW, decide(dialer, rs, at(DayOfWeek.MONDAY, 12)))
        assertEquals(Decision.BLOCK, decide(thirdParty, rs, at(DayOfWeek.MONDAY, 12)))

        val limited = rules().copy(
            appRules = listOf(
                AppRuleDto(packageId = dialer, appName = "Phone", action = "time_limit", dailyLimitMinutes = 1),
                AppRuleDto(packageId = thirdParty, appName = "Game", action = "time_limit", dailyLimitMinutes = 1),
            ),
        )
        val used = mapOf(dialer to 5, thirdParty to 5)
        assertEquals(Decision.ALLOW, decide(dialer, limited, at(DayOfWeek.MONDAY, 12), used = used))
        assertEquals(Decision.TIME_LIMIT_REACHED, decide(thirdParty, limited, at(DayOfWeek.MONDAY, 12), used = used))
    }

    @Test
    fun `school hours cannot cover the essential set`() {
        val rs = rules().copy(
            screenTime = rules().screenTime.copy(
                schoolHours = SchoolHoursDto(start = "09:00", end = "15:00", days = listOf(1)),
            ),
        )
        assertOnlyEssentialsExempt(Decision.BLOCK, rs, at(DayOfWeek.MONDAY, 10))
    }

    @Test
    fun `consent withdrawn still allows everything, essential or not`() {
        for (pkg in essentials + thirdParty) {
            assertEquals(pkg, Decision.ALLOW, decide(pkg, rules(), at(DayOfWeek.MONDAY, 22), consentPaused = true))
        }
    }

    @Test
    fun `the exemption is the essential set, not a wildcard on names`() {
        // Review of #83 F1: a sideloaded `*.dialer` used to escape fail-closed. It must not.
        assertEquals(Decision.BLOCK, decide("com.evil.dialer", null, at(DayOfWeek.MONDAY, 22)))
        assertEquals(Decision.BLOCK, decide("com.evil.dialer", rules(), at(DayOfWeek.MONDAY, 22)))
        assertEquals(Decision.ALLOW, decide("com.evil.dialer", rules(), at(DayOfWeek.MONDAY, 12)))

        // Issue #192: sharing our namespace is not the same package. The old prefix exemption let a
        // sideloaded `com.familyshield.notanapp` through every rule on the decision path too.
        assertEquals(
            "com.familyshield.notanapp",
            Decision.BLOCK,
            decide("com.familyshield.notanapp", null, at(DayOfWeek.MONDAY, 22)),
        )
        assertEquals(
            "com.familyshield.notanapp",
            Decision.BLOCK,
            decide("com.familyshield.notanapp", rules(), at(DayOfWeek.MONDAY, 22)),
        )
        assertEquals(
            EssentialPackages.OWN_PACKAGE,
            Decision.ALLOW,
            decide(EssentialPackages.OWN_PACKAGE, rules(), at(DayOfWeek.MONDAY, 22)),
        )
    }

    @Test
    fun `the essential set the decision path uses is the overlay's set`() {
        for (pkg in essentials) {
            org.junit.Assert.assertTrue("$pkg must be in EssentialPackages.EXACT", pkg in EssentialPackages.EXACT)
        }
    }
}
