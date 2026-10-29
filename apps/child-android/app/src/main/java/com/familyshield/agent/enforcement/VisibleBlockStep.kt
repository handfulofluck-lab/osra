package com.familyshield.agent.enforcement

import com.familyshield.agent.data.RuleRepository.Decision

/** The blocked package found in one snapshot, its decision, and what [BlockRaisePolicy] said to do. */
data class VisibleBlock(val pkg: String, val decision: Decision, val step: BlockRaise)

/**
 * Issue #175: the service's per-event block step, kept free of Android types so the JVM suite can pin it.
 *
 * Every candidate from [EssentialPackages.blockCandidates] is evaluated in order; the first non-ALLOW
 * answer goes to [BlockRaisePolicy]. An essential package (dialer, emergency, launcher, our own app)
 * answers ALLOW in `RuleRepository.decide`, so it never reaches the policy.
 *
 * Home is masked on top of that: `GLOBAL_ACTION_HOME` is never sent while the **active** window is an
 * essential package. With the dialer in front and a blocked video in PiP, Home would throw a live call
 * to the home screen (Claude's note on #175); the cover and the block screen still deal with the video.
 */
object VisibleBlockStep {
    fun decide(
        snapshot: WindowSnapshot,
        active: String?,
        evaluate: (String) -> Decision,
        isEssential: (String) -> Boolean,
        policy: BlockRaisePolicy,
        nowMs: Long,
    ): VisibleBlock? {
        for (pkg in EssentialPackages.blockCandidates(active, snapshot.windows)) {
            val decision = evaluate(pkg)
            if (decision == Decision.ALLOW) continue
            val step = policy.decide(pkg, snapshot.layout, blockedIsActive = pkg == active, nowMs = nowMs)
            val homeIsSafe = active == null || active == pkg || !isEssential(active)
            return VisibleBlock(pkg, decision, if (homeIsSafe) step else step.copy(goHome = false))
        }
        policy.noBlockedWindow()
        return null
    }
}
