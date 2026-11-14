package com.familyshield.agent.enforcement

import com.familyshield.agent.data.RuleEngine
import com.familyshield.agent.data.RuleRepository
import com.familyshield.agent.data.RuleRepository.Decision
import com.familyshield.agent.network.dto.AppRuleDto
import com.familyshield.agent.network.dto.RuleSetDto
import java.time.LocalDate
import java.time.LocalTime
import java.time.ZoneOffset
import java.time.ZonedDateTime
import org.junit.Assert.assertEquals
import org.junit.Test

/**
 * Issue #671 (Flip4 scenario run 1, #665): a block screen the child left with Home is never finished,
 * so the next agent screen to close — the ring, or the keyguard's bouncer — uncovers it. The child saw
 * "This app is blocked by your parent · Calculator" seven minutes after the parent lifted the block,
 * with nothing blocked.
 *
 * The fix is a re-check: [BlockActivity] asks the rules again for the package it is showing, and takes
 * itself down when the answer is ALLOW. This class pins the decision table, driving the **real**
 * [RuleRepository.decide] gate and the **real** [RuleEngine] walk, so every row is the answer production
 * gets rather than a hand-made one.
 *
 * The fail-closed rows are the important ones. A re-check that takes the screen down when it cannot
 * tell is a worse bug than #671: it unblocks an app the parent blocked. So:
 *
 * - **no cached rules while paired** — `RuleRepository.decideWithReason` answers BLOCK (AND-03), and
 *   the screen stays;
 * - **a snapshot that has not caught up** — the re-check reads the rules the phone holds, so a parent's
 *   unblock that has not reached the device yet still reads BLOCK, and the screen stays. The screen can
 *   live too long; it can never come down early on a guess;
 * - **a blank package** — the screen cannot name what it is blocking, so it stays whatever the
 *   decision says.
 *
 * Mutants, one per row (each names the row that goes red):
 * - return `KEEP` unconditionally (no re-check at all) → [a resumed screen closes when the rules no longer block its app];
 * - `decision != Decision.BLOCK` instead of `decision == Decision.ALLOW` (fails open on a limit) →
 *   [a resumed screen stays while the daily limit is still reached];
 * - drop the blank-package guard → [a screen that cannot name its package stays whatever the decision says];
 * - drop the `paired` argument from the walk (read "no rules" as allow) →
 *   [an unknown rule set keeps the screen up].
 */
class BlockRecheckPolicyTest {

    private val engine = RuleEngine()
    private val calculator = "com.android.calculator2"

    /** Monday 12:00, outside the default 21:00–07:00 bedtime window. */
    private val noon: ZonedDateTime =
        ZonedDateTime.of(LocalDate.of(2026, 11, 9), LocalTime.of(12, 0), ZoneOffset.UTC)

    /** The same walk `RuleRepository.verdict` performs, minus the Android-backed sources (#165's shape). */
    private fun decide(
        pkg: String,
        rules: RuleSetDto?,
        paired: Boolean = true,
        consentPaused: Boolean = false,
    ): Decision = RuleRepository.decide(pkg, rules, paired, consentPaused) { active ->
        engine.evaluate(active, pkg, noon)
    }

    /** What the phone holds after the parent lifted the block: an explicit allow for Calculator. */
    private fun lifted() = RuleSetDto(
        appRules = listOf(AppRuleDto(packageId = calculator, appName = "Calculator", action = "allow")),
    )

    /** What the phone still held at 19:03Z, when the screen went up. */
    private fun blocking() = RuleSetDto(
        appRules = listOf(AppRuleDto(packageId = calculator, appName = "Calculator", action = "block")),
    )

    /** The issue's row: resumed for a package the current rules allow, the screen finishes at once. */
    @Test
    fun `a resumed screen closes when the rules no longer block its app`() {
        val decision = decide(calculator, lifted())
        assertEquals("the parent's unblock has reached this phone", Decision.ALLOW, decision)
        assertEquals(BlockRecheckPolicy.Action.FINISH, BlockRecheckPolicy.decide(calculator, decision))
    }

    /** The other half: still blocked, still covered. */
    @Test
    fun `a resumed screen stays while the rules still block its app`() {
        val decision = decide(calculator, blocking())
        assertEquals(Decision.BLOCK, decision)
        assertEquals(BlockRecheckPolicy.Action.KEEP, BlockRecheckPolicy.decide(calculator, decision))
    }

    /**
     * The app's own time limit is a block with a different decision value. A policy written as
     * `decision != BLOCK` would take this screen down and hand back an app whose limit is used up.
     */
    @Test
    fun `a resumed screen stays while the daily limit is still reached`() {
        val limited = RuleSetDto(
            appRules = listOf(
                AppRuleDto(
                    packageId = calculator,
                    appName = "Calculator",
                    action = "time_limit",
                    dailyLimitMinutes = 10,
                ),
            ),
        )
        val verdict = RuleRepository.decide(calculator, limited, paired = true, consentPaused = false) { active ->
            engine.evaluate(active, calculator, noon, minutesUsedToday = mapOf(calculator to 10))
        }
        assertEquals(Decision.TIME_LIMIT_REACHED, verdict)
        assertEquals(BlockRecheckPolicy.Action.KEEP, BlockRecheckPolicy.decide(calculator, verdict))
    }

    /**
     * AND-03: paired with nothing cached answers BLOCK for an app. The re-check inherits that, which is
     * exactly why it is safe to run on resume — "I do not know" is not "allowed".
     */
    @Test
    fun `an unknown rule set keeps the screen up`() {
        val decision = decide(calculator, rules = null)
        assertEquals("an empty cache fails closed for an app (AND-03)", Decision.BLOCK, decision)
        assertEquals(BlockRecheckPolicy.Action.KEEP, BlockRecheckPolicy.decide(calculator, decision))
    }

    /**
     * The 19:10Z state in the scenario: the parent lifted the block at 19:04Z, but the device's snapshot
     * was v8 (which blocks Calculator) until the next rules sync. The screen stays up under that
     * snapshot — the safe direction, and the one #671 makes visible only until the rules arrive.
     */
    @Test
    fun `a snapshot that has not yet caught up keeps the screen up`() {
        assertEquals(
            BlockRecheckPolicy.Action.KEEP,
            BlockRecheckPolicy.decide(calculator, decide(calculator, blocking())),
        )
        // The same package once the snapshot does catch up: the screen goes.
        assertEquals(
            BlockRecheckPolicy.Action.FINISH,
            BlockRecheckPolicy.decide(calculator, decide(calculator, lifted())),
        )
    }

    /**
     * An ADR-0008 §3 paused agent enforces nothing, and the accessibility service stops raising blocks
     * while paused, so a screen left over from before the withdrawal comes down rather than staying.
     */
    @Test
    fun `a screen left over from before consent was withdrawn closes`() {
        val decision = decide(calculator, blocking(), consentPaused = true)
        assertEquals(Decision.ALLOW, decision)
        assertEquals(BlockRecheckPolicy.Action.FINISH, BlockRecheckPolicy.decide(calculator, decision))
    }

    /**
     * The policy fails closed on its own input too: an intent that named no package (a malformed or
     * foreign launch) cannot be re-checked, so the screen is not taken down on an ALLOW it cannot read.
     */
    @Test
    fun `a screen that cannot name its package stays whatever the decision says`() {
        for (decision in Decision.values()) {
            assertEquals(
                "$decision for an unnamed package must not close the screen",
                BlockRecheckPolicy.Action.KEEP,
                BlockRecheckPolicy.decide("", decision),
            )
        }
    }
}
