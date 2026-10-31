package com.familyshield.agent

import com.familyshield.agent.data.RuleEngine
import com.familyshield.agent.data.RuleRepository
import com.familyshield.agent.data.Verdict
import com.familyshield.agent.data.RuleRepository.Decision
import com.familyshield.agent.enforcement.BlockRaisePolicy
import com.familyshield.agent.enforcement.EssentialPackages
import com.familyshield.agent.enforcement.LockEnforcementPolicy
import com.familyshield.agent.enforcement.OverlayRetryBudget
import com.familyshield.agent.enforcement.PackageFacts
import com.familyshield.agent.enforcement.RetryDecision
import com.familyshield.agent.enforcement.VisibleBlockStep
import com.familyshield.agent.enforcement.VisibleWindow
import com.familyshield.agent.enforcement.WindowLayout
import com.familyshield.agent.enforcement.WindowSnapshot
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
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Issue #175: #171 decided every block from `rootInActiveWindow` alone, so a blocked app that was
 * **visible but not active** — a YouTube video in picture-in-picture over Home, or the blocked app in
 * the other half of a split screen — was never judged. These tests pin the input to the decision:
 * every visible application window (active, split sibling, PiP) is a block candidate, while a window
 * the child cannot see (a background app's content-change event) is not.
 *
 * The lock has the same hole in its re-raise trigger: with the launcher active and a blocked app in
 * PiP or beside it, `shouldReraise(active)` answered false, so the overlay was never brought back.
 *
 * Each PiP/split assertion fails on the tree before this change, where `blockCandidates` and the
 * snapshot overload of `shouldReraise` look only at the active package.
 */
class MultiWindowCoverageTest {

    private val engine = RuleEngine()

    // Derived, so a future applicationId cannot make these rows assert about a package that is not us.
    private val own = EssentialPackages.OWN_PACKAGE
    private val launcher = "com.sec.android.app.launcher"
    private val chrome = "com.android.chrome"
    private val youtube = "com.google.android.youtube"
    private val dialer = "com.samsung.android.dialer"

    /** The bedtime rule from the Flip4 run: 21:00–07:00, no other rule. */
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

    private fun decide(pkg: String, facts: PackageFacts = FakeFacts()): Decision =
        RuleRepository.decide(
            packageId = pkg,
            ruleSet = bedtime,
            paired = true,
            consentPaused = false,
            essential = { EssentialPackages.isEssential(it, facts) },
        ) { active -> engine.evaluate(active, pkg, now) }

    /**
     * What the service does with a snapshot: resolve the candidates from every visible window, then
     * run the same decision on each until one answers something other than ALLOW.
     */
    private fun firstBlocked(
        active: String?,
        windows: List<VisibleWindow>,
        facts: PackageFacts = FakeFacts(),
    ): Decision? {
        for (pkg in EssentialPackages.blockCandidates(active, windows)) {
            val decision = decide(pkg, facts)
            if (decision != Decision.ALLOW) return decision
        }
        return null
    }

    @Test
    fun `split screen - a blocked app beside the launcher is judged and blocked`() {
        val windows = listOf(
            VisibleWindow(launcher),
            VisibleWindow(chrome),
        )
        val snapshot = WindowSnapshot(launcher, windows)

        assertEquals(WindowLayout.SPLIT_SCREEN, snapshot.layout)
        assertEquals(listOf(chrome), EssentialPackages.blockCandidates(launcher, windows))
        assertEquals(Decision.BLOCK, firstBlocked(launcher, windows))
    }

    @Test
    fun `picture-in-picture - a blocked video over the launcher is judged and blocked`() {
        val windows = listOf(
            VisibleWindow(launcher),
            VisibleWindow(youtube, inPictureInPicture = true),
        )
        val snapshot = WindowSnapshot(launcher, windows)

        assertEquals(WindowLayout.PICTURE_IN_PICTURE, snapshot.layout)
        assertEquals(listOf(youtube), EssentialPackages.blockCandidates(launcher, windows))
        assertEquals(Decision.BLOCK, firstBlocked(launcher, windows))
    }

    @Test
    fun `normal - one visible app is still judged from that app`() {
        val windows = listOf(VisibleWindow(chrome))
        val snapshot = WindowSnapshot(chrome, windows)

        assertEquals(WindowLayout.NORMAL, snapshot.layout)
        assertEquals(listOf(chrome), EssentialPackages.blockCandidates(chrome, windows))
        assertEquals(Decision.BLOCK, firstBlocked(chrome, windows))
    }

    @Test
    fun `a background app with no visible window is not judged - the 171 spay case`() {
        // #171 fixed this: `com.samsung.android.spay`'s content-change event named an app that was not
        // on screen and raised an overlay over the launcher. With no visible application window there
        // is no candidate and no overlay.
        assertEquals(emptyList<String>(), EssentialPackages.blockCandidates(null, emptyList()))
        assertNull(firstBlocked(null, emptyList()))

        // The launcher alone is essential: it is filtered before the rule ever runs.
        assertEquals(
            emptyList<String>(),
            EssentialPackages.blockCandidates(launcher, listOf(VisibleWindow(launcher))),
        )
        assertNull(firstBlocked(launcher, listOf(VisibleWindow(launcher))))
    }

    @Test
    fun `our own overlay and the framework package are never block candidates`() {
        val windows = listOf(
            VisibleWindow(own),
            VisibleWindow("android"),
            VisibleWindow(chrome),
        )
        assertEquals(listOf(chrome), EssentialPackages.blockCandidates(own, windows))
    }

    @Test
    fun `the lock is re-raised over a split sibling and a PiP window`() {
        val facts = FakeFacts(system = setOf(dialer))
        val split = WindowSnapshot(
            launcher,
            listOf(VisibleWindow(launcher), VisibleWindow(chrome)),
        )
        val pip = WindowSnapshot(
            launcher,
            listOf(VisibleWindow(launcher), VisibleWindow(youtube, inPictureInPicture = true)),
        )
        assertTrue(LockEnforcementPolicy.shouldReraise("locked", split, own, facts))
        assertTrue(LockEnforcementPolicy.shouldReraise("paused", pip, own, facts))
        assertTrue(LockEnforcementPolicy.shouldReraise("paused_internet", pip, own, facts))
    }

    @Test
    fun `the lock does not re-raise when the overlay itself is the only window`() {
        val facts = FakeFacts()
        val covered = WindowSnapshot(own, listOf(VisibleWindow(own)))
        assertFalse(LockEnforcementPolicy.shouldReraise("locked", covered, own, facts))
        assertFalse(LockEnforcementPolicy.shouldReraise("none", covered, own, facts))
        assertFalse(
            "no window and no active package is not a reason to raise",
            LockEnforcementPolicy.shouldReraise("locked", WindowSnapshot(null, emptyList()), own, facts),
        )
    }

    @Test
    fun `our own activity in PiP may be replaced - a PiP overlay is not coverage`() {
        // A PiP window floats above the app behind it and is not a full-screen gate. If our own
        // overlay ever ends up there, the policy must let the service raise (and expand) it again.
        val ownPip = WindowSnapshot(own, listOf(VisibleWindow(own, inPictureInPicture = true)))
        assertTrue(LockEnforcementPolicy.shouldReraise("locked", ownPip, own, FakeFacts()))

        // The same PiP state with a call surface on screen must not pull the overlay over the call.
        val dialerFacts = FakeFacts(system = setOf(dialer))
        val callPip = WindowSnapshot(
            dialer,
            listOf(VisibleWindow(dialer), VisibleWindow(own, inPictureInPicture = true)),
        )
        assertFalse(LockEnforcementPolicy.shouldReraise("locked", callPip, own, dialerFacts))
    }

    /** The service's per-event block step over [snapshot], with the dialer a system app as on the Flip4. */
    private fun step(snapshot: WindowSnapshot, policy: BlockRaisePolicy, nowMs: Long) =
        FakeFacts(system = setOf(dialer)).let { facts ->
            VisibleBlockStep.decide(
                snapshot,
                snapshot.activePackage,
                evaluate = { Verdict(decide(it, facts)) },
                isEssential = { EssentialPackages.isEssential(it, facts) },
                policy = policy,
                nowMs = nowMs,
            )
        }

    @Test
    fun `a call at bedtime is never sent Home - the dialer is not a block candidate`() {
        val policy = BlockRaisePolicy()
        val call = WindowSnapshot(dialer, listOf(VisibleWindow(dialer)))
        repeat(10) { i -> assertNull("event $i", step(call, policy, 1_000L * i)) }
    }

    @Test
    fun `a blocked video in PiP over a call is covered and raised, but Home is not sent over the call`() {
        val policy = BlockRaisePolicy()
        val callWithPip = WindowSnapshot(dialer, listOf(VisibleWindow(dialer), VisibleWindow(youtube, inPictureInPicture = true)))
        val found = step(callWithPip, policy, 0L)!!

        assertEquals(youtube, found.pkg)
        assertTrue(found.step.raise)
        assertFalse("Home would end the call's screen", found.step.goHome)
    }

    @Test
    fun `Home is still sent when the blocked app itself is in front`() {
        val found = step(WindowSnapshot(chrome, listOf(VisibleWindow(chrome))), BlockRaisePolicy(), 0L)!!
        assertEquals(chrome, found.pkg)
        assertTrue(found.step.goHome)
    }

    @Test
    fun `the retry budget is bounded per screen state and resets when the state changes`() {
        val budget = OverlayRetryBudget(maxAttempts = 3)
        // A steady state — the platform keeps PiP above our overlay — gets three raises and then
        // stops, logging the exhaustion once instead of starting an activity on every event.
        assertEquals(RetryDecision.ATTEMPT, budget.attempt("own:win,youtube:pip"))
        assertEquals(RetryDecision.ATTEMPT, budget.attempt("own:win,youtube:pip"))
        assertEquals(RetryDecision.ATTEMPT, budget.attempt("own:win,youtube:pip"))
        assertEquals(RetryDecision.EXHAUSTED_ONCE, budget.attempt("own:win,youtube:pip"))
        assertEquals(RetryDecision.EXHAUSTED, budget.attempt("own:win,youtube:pip"))

        // The child closed PiP: the screen state changed, so the overlay may be raised again.
        assertEquals(RetryDecision.ATTEMPT, budget.attempt("own:win"))
    }

    @Test
    fun `the signature ignores window order and duplicate windows of one app`() {
        val a = WindowSnapshot(
            launcher,
            listOf(VisibleWindow(launcher), VisibleWindow(chrome), VisibleWindow(youtube, inPictureInPicture = true)),
        )
        val b = WindowSnapshot(
            launcher,
            listOf(VisibleWindow(youtube, inPictureInPicture = true), VisibleWindow(chrome), VisibleWindow(launcher)),
        )
        assertEquals(a.signature, b.signature)

        val duplicate = WindowSnapshot(chrome, listOf(VisibleWindow(chrome), VisibleWindow(chrome)))
        assertEquals(WindowLayout.NORMAL, duplicate.layout)
        assertEquals(listOf(chrome), EssentialPackages.blockCandidates(chrome, duplicate.windows))
    }
}
