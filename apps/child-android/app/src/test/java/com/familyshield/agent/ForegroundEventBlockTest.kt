package com.familyshield.agent

import com.familyshield.agent.data.RuleEngine
import com.familyshield.agent.data.RuleRepository
import com.familyshield.agent.data.RuleRepository.Decision
import com.familyshield.agent.enforcement.EssentialPackages
import com.familyshield.agent.enforcement.PackageFacts
import com.familyshield.agent.network.dto.RuleSetDto
import com.familyshield.agent.network.dto.SchoolHoursDto
import com.familyshield.agent.network.dto.ScreenTimeRuleDto
import java.time.LocalDate
import java.time.LocalTime
import java.time.ZoneOffset
import java.time.ZonedDateTime
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Test

/**
 * Issue #165, reopened on hardware (2026-10-19): the defect was never in the essential *set*, it was
 * in the set's input. With bedtime active on the Flip4 (Android 16, WM-Shell), the Home transition
 * arrives as an accessibility event whose `packageName` is **`android`** — the framework — and not
 * `com.sec.android.app.launcher`. `com.sec.android.app.launcher` is in [EssentialPackages.EXACT], so
 * the exemption would have applied had the event named the launcher; instead the decision was made
 * for the framework package and [com.familyshield.agent.enforcement.BlockActivity] was raised over
 * the home screen (`C:\KARIM\tr-kimi\hw-2026-10-19\RESULTS-165.md`, rows 3a and 3b).
 *
 * These tests run the service's sequence — resolve the package in front, then decide — and pin both
 * halves: the framework-package event is **allowed** when the window in front is the launcher, and a
 * genuinely blocked app is still blocked. They fail on the tree merged as #169, where the event
 * package went straight into the decision.
 */
class ForegroundEventBlockTest {

    private val engine = RuleEngine()

    private val launcher = "com.sec.android.app.launcher"
    private val chrome = "com.android.chrome"

    /** Exactly the bedtime rule the Flip4 run had active: 21:00–07:00, no other rule. */
    private val bedtime = RuleSetDto(
        screenTime = ScreenTimeRuleDto(
            dailyLimitMinutes = 10_080,
            weekendLimitMinutes = 10_080,
            bedtimeStart = "21:00",
            bedtimeEnd = "07:00",
            schoolHours = SchoolHoursDto(days = emptyList()),
        ),
    )

    /** Device-local 22:00 on a Monday, inside the bedtime window. */
    private val now: ZonedDateTime = ZonedDateTime.of(
        LocalDate.of(2026, 10, 19),
        LocalTime.of(22, 0),
        ZoneOffset.UTC,
    )

    private class FakeFacts(
        private val system: Set<String> = emptySet(),
        private val homes: Set<String> = emptySet(),
    ) : PackageFacts {
        override fun isSystemApp(pkg: String): Boolean = pkg in system
        override fun dialerRoleHolders(): Set<String> = emptySet()
        override fun homePackages(): Set<String> = homes
    }

    /**
     * The service's order (`AccessibilityMonitorService.onAccessibilityEvent`): the event package is
     * a hint, the window actually in front is what the block decision is about. `null` is "no app to
     * name" — the service raises no overlay for it.
     */
    private fun decisionForEvent(
        eventPackage: String,
        windowPackage: String?,
        facts: PackageFacts = FakeFacts(),
    ): Decision? {
        val foreground = EssentialPackages.foregroundPackage(eventPackage, windowPackage) ?: return null
        return RuleRepository.decide(
            packageId = foreground,
            ruleSet = bedtime,
            paired = true,
            consentPaused = false,
            essential = { EssentialPackages.isEssential(it, facts) },
        ) { active -> engine.evaluate(active, foreground, now) }
    }

    @Test
    fun `the measured Home case is allowed - framework event package, launcher in front`() {
        // The two facts from the Flip4 run: the event names "android", the screen is the launcher.
        assertEquals(launcher, EssentialPackages.foregroundPackage("android", launcher))
        assertEquals(Decision.ALLOW, decisionForEvent("android", launcher))
        // An event from the launcher itself stays allowed — that is the path #169 already covered.
        assertEquals(Decision.ALLOW, decisionForEvent(launcher, launcher))
    }

    @Test
    fun `a genuinely blocked app is still blocked while bedtime is active`() {
        assertEquals(Decision.BLOCK, decisionForEvent(chrome, chrome))
        // The window in front decides: a framework-named event over Chrome is still Chrome.
        assertEquals(Decision.BLOCK, decisionForEvent("android", chrome))
    }

    @Test
    fun `a framework event with no window association raises no overlay`() {
        // Do not exempt the framework package by name — it fronts dialogs and the shell — and do not
        // guess an app either: with nothing in front that can be named, there is no block to raise.
        assertFalse(EssentialPackages.isEssential("android"))
        assertNull(EssentialPackages.foregroundPackage("android", null))
        assertNull(EssentialPackages.foregroundPackage("android", "android"))
        assertNull(decisionForEvent("android", null))
        // An ordinary app still uses its event package when the window is unknown.
        assertEquals(Decision.BLOCK, decisionForEvent(chrome, null))
    }

    @Test
    fun `a background app's event is decided from the window in front, not from the event`() {
        // Measured in the reopened run: `com.samsung.android.spay`'s content-change event named the
        // overlay while the launcher/dialer held focus, and Home from that overlay put it back. The
        // resolver is the same one, so the decision belongs to the screen in front.
        assertEquals(launcher, EssentialPackages.foregroundPackage("com.samsung.android.spay", launcher))
        assertEquals(Decision.ALLOW, decisionForEvent("com.samsung.android.spay", launcher))
        // And a blocked app in front stays blocked, whatever emitted the event.
        assertEquals(Decision.BLOCK, decisionForEvent(launcher, chrome))
    }

    @Test
    fun `an OEM launcher resolved by the HOME role is allowed though the table never heard of it`() {
        val oem = "com.oneplus.launcher"
        assertFalse("the static table must not know this name", oem in EssentialPackages.EXACT)
        val facts = FakeFacts(homes = setOf(oem))
        assertEquals(oem, EssentialPackages.foregroundPackage("android", oem))
        assertEquals(Decision.ALLOW, decisionForEvent("android", oem, facts))
        // The role is what exempts it: without the OS saying it is HOME, the name buys nothing.
        assertEquals(Decision.BLOCK, decisionForEvent("android", oem))
    }

    @Test
    fun `the launcher is still covered by a lock - the essential set is not the lock's set`() {
        // Plan 1.3/ADR-0010: the lock must come back over Home. This change only touches the block
        // path; the assertions here are the ones `EssentialPackagesTest` already pins, restated for
        // the resolved (not event) package so the two paths cannot drift.
        val facts = FakeFacts(system = setOf(launcher))
        assertEquals(launcher, EssentialPackages.foregroundPackage("android", launcher))
        assertEquals(
            true,
            com.familyshield.agent.enforcement.LockEnforcementPolicy.shouldReraise(
                "locked",
                EssentialPackages.foregroundPackage("android", launcher),
                "com.familyshield.agent",
                facts,
            ),
        )
    }
}
