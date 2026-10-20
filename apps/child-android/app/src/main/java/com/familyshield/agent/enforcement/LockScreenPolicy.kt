package com.familyshield.agent.enforcement

/**
 * What `LockActivity` must draw, given what [LockState] says and what the launch intent asked for
 * (issue #233 review, F1/F2).
 *
 * The intent is a **wake-up**, not the truth. `LockState` is written before every launch
 * (`CommandDispatcher.lock`/`pause`/`pauseInternet` set it, `unlock` clears it), so it is what the
 * parent's current command says should be on screen. Drawing from the intent instead produced a
 * measured bug on the Flip4 (2026-10-20): a refused `lock` left an activity record that never
 * started, a following `unlock` queued `MODE_UNLOCK` on that record, and when the launch later
 * became allowed the replayed intent finished the brand-new lock screen 5 ms after it appeared —
 * while the `lock` ack said `via=overlay`. With this rule replayed intents converge on the stored
 * mode, so a stale intent cannot cancel a live lock.
 *
 * Stored state crossed with intent:
 * - stored **locked/paused/paused_internet** → [Decision.Show] that mode, whatever the intent says
 *   (a lock, pause or dismiss intent may be the wake-up, the stored mode is what is enforced);
 * - stored **none** (or anything not a locking mode) → nothing of ours belongs on screen:
 *   [Decision.DismissKeyguard] when the intent was `unlock` (so the keyguard our own `lockNow()`
 *   raised can be dismissed), [Decision.Finish] otherwise.
 *
 * Pure on purpose (JVM-tested): no Android types, so the whole 12-row table is held by the suite.
 */
object LockScreenPolicy {

    /** `LockActivity.MODE_UNLOCK`: the only intent mode that dismisses the keyguard. */
    private const val INTENT_UNLOCK = "unlock"

    sealed interface Decision {
        /**
         * Draw the stored locking screen. [mode] is one of `locked`, `paused`, `paused_internet`
         * and is always the value read from [LockState], never the intent's extra.
         */
        data class Show(val mode: String) : Decision

        /** Nothing of ours is stored and the intent was `unlock`: dismiss the keyguard, then finish. */
        data object DismissKeyguard : Decision

        /** Nothing of ours is stored: finish without touching the keyguard. */
        data object Finish : Decision
    }

    /**
     * Resolves the screen for [storedMode] ([LockState.mode]) and [intentMode]
     * (`LockActivity.EXTRA_MODE`; null means the activity's default, `locked`).
     *
     * A stored value that is not a locking mode — `none`, blank, or an unknown string — is treated
     * as "nothing should be on screen": drawing a lock because the mode was unrecognised would be a
     * false lock, and the safe direction for an unknown stored state is to take the overlay down.
     */
    fun resolve(storedMode: String?, intentMode: String?): Decision {
        val stored = storedMode?.takeIf { LockEnforcementPolicy.isLockingMode(it) }
        if (stored != null) return Decision.Show(stored)
        return if (intentMode == INTENT_UNLOCK) Decision.DismissKeyguard else Decision.Finish
    }
}
