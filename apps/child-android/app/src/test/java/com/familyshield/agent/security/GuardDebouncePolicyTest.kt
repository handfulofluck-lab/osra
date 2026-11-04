package com.familyshield.agent.security

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * #533 review: the guard may skip a protection screen only while the PIN gate is in front or still coming up.
 *
 * Mutants (Claude's): the debounce ignores `gateShowing` → [the gate left inside 1.5 s is guarded] stays
 * green but [the gate showing suppresses, past the window too] goes red; the flag is never cleared → the
 * wiring row in [TamperGuardLandsHomeWiringTest] goes red; time alone (the old rule) → [the gate left inside
 * 1.5 s is guarded] goes red.
 */
class GuardDebouncePolicyTest {

    private val t0 = 1_000_000L

    @Test
    fun `the gate showing suppresses, past the window too`() {
        assertTrue(GuardDebouncePolicy.suppress(t0 + 200, t0, gateShowing = true, gateResumedSinceLaunch = true))
        assertTrue(GuardDebouncePolicy.suppress(t0 + 60_000, t0, gateShowing = true, gateResumedSinceLaunch = true))
    }

    @Test
    fun `a launch still pending suppresses`() {
        assertTrue(GuardDebouncePolicy.suppress(t0 + 300, t0, gateShowing = false, gateResumedSinceLaunch = false))
    }

    @Test
    fun `the gate left inside 1_5 s is guarded`() {
        // Recents → Settings: the gate came up and paused; the sheet's state change arrives inside the window.
        assertFalse(GuardDebouncePolicy.suppress(t0 + 900, t0, gateShowing = false, gateResumedSinceLaunch = true))
    }

    @Test
    fun `past the window, a gate that never came up is launched again`() {
        assertFalse(GuardDebouncePolicy.suppress(t0 + 1_500, t0, gateShowing = false, gateResumedSinceLaunch = false))
        assertFalse(GuardDebouncePolicy.suppress(t0 + 5_000, t0, gateShowing = false, gateResumedSinceLaunch = true))
    }

    @Test
    fun `resumedSince counts only a resume after the launch`() {
        GuardGateState.lastResumedMs = 0L
        assertFalse("never resumed", GuardGateState.resumedSince(0L))
        GuardGateState.lastResumedMs = t0 - 1
        assertFalse("an earlier gate does not count", GuardGateState.resumedSince(t0))
        GuardGateState.lastResumedMs = t0 + 250
        assertTrue(GuardGateState.resumedSince(t0))
        GuardGateState.lastResumedMs = 0L
    }
}
