package com.familyshield.agent.enforcement

import com.familyshield.agent.data.RuleRepository.Decision

/**
 * Issue #671: may the block screen take itself down?
 *
 * `BlockActivity` used to stay up until the child pressed "Exit to Home screen", so a screen the child
 * left with Home was still there behind the next agent screen — the ring, or the keyguard. On the Flip4
 * (scenario run 1, #665) the child read "This app is blocked by your parent · Calculator" at 19:10Z,
 * seven minutes after the parent lifted the block at 19:04Z, on the `BlockActivity` record from 19:03Z.
 *
 * The answer this policy gives is **the same walk that raised the screen** (`RuleRepository.verdict`),
 * asked again for the package the screen is showing. Two directions are wrong in different ways, so the
 * rule is deliberately narrow:
 *
 * - **FINISH only for [Decision.ALLOW].** A time limit that is still reached is a block with another
 *   name; a policy written as "not BLOCK" would hand back an app whose limit is used up.
 * - **KEEP for everything else, including every "I do not know".** `RuleRepository.decideWithReason`
 *   answers BLOCK when the phone is paired and nothing is cached (AND-03), and the screen keeps that
 *   answer. A re-check that fails open would unblock an app the parent blocked — worse than #671.
 *
 * A **stale** snapshot reads the same way: the re-check consults the rules the phone holds, so a
 * parent's unblock that has not synced yet still answers BLOCK and the screen stays up until the next
 * FCM/poll sync lands. The screen can outlive an unblock by one sync interval; it can never come down
 * on a guess.
 *
 * A [packageId] that is blank is refused before the decision is read: the screen does not know what it
 * is blocking, so there is nothing to re-check and nothing that justifies taking it down.
 */
object BlockRecheckPolicy {

    /** What [BlockActivity] does with the answer it gets on resume or on stop. */
    enum class Action {
        /** Keep the screen: the app is still blocked, or the rules cannot say it is not. */
        KEEP,

        /** Take the screen down: the current rules allow the app. */
        FINISH,
    }

    fun decide(packageId: String, decision: Decision): Action = when {
        packageId.isBlank() -> Action.KEEP
        decision == Decision.ALLOW -> Action.FINISH
        else -> Action.KEEP
    }
}
