package com.familyshield.agent.security

import org.junit.Assert.assertEquals
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

    // osra-security#7 rows. Mutants: drop `gateMultiWindow` from the rule → [a gate sharing the screen never
    // suppresses] goes red; drop `newWindow` → [a new window is judged while the gate is up] goes red.

    @Test
    fun `a gate sharing the screen never suppresses`() {
        assertFalse(GuardDebouncePolicy.suppress(t0 + 200, t0, gateShowing = true, gateResumedSinceLaunch = true, gateMultiWindow = true))
        assertFalse(GuardDebouncePolicy.suppress(t0 + 60_000, t0, gateShowing = true, gateResumedSinceLaunch = true, gateMultiWindow = true))
        assertFalse(GuardDebouncePolicy.suppress(t0 + 300, t0, gateShowing = false, gateResumedSinceLaunch = false, gateMultiWindow = true))
    }

    @Test
    fun `a new window is judged while the gate is up`() {
        assertFalse(GuardDebouncePolicy.suppress(t0 + 60_000, t0, gateShowing = true, gateResumedSinceLaunch = true, newWindow = true))
        // inside the launch window too: a re-open of a different window is not the launch it waits for
        assertFalse(GuardDebouncePolicy.suppress(t0 + 300, t0, gateShowing = false, gateResumedSinceLaunch = false, newWindow = true))
        // the window the gate was opened over still suppresses
        assertTrue(GuardDebouncePolicy.suppress(t0 + 300, t0, gateShowing = true, gateResumedSinceLaunch = true, newWindow = false))
    }

    // Review of #546: the guard's gate goes Home when sharing (a relaunch landed on itself and closed it); an
    // in-app gate never refuses, or its caller loses the result. Mutants: refuse for every gate → [in-app gates
    // never refuse]; never refuse → [the guard's gate sharing the screen goes Home].

    @Test
    fun `the guard's gate sharing the screen goes Home`() {
        assertTrue(GuardMultiWindowPolicy.goHome(guardGate = true, inMultiWindow = true))
        assertFalse(GuardMultiWindowPolicy.goHome(guardGate = true, inMultiWindow = false))
    }

    @Test
    fun `in-app gates never refuse`() {
        assertFalse(GuardMultiWindowPolicy.goHome(guardGate = false, inMultiWindow = true))
        assertFalse(GuardMultiWindowPolicy.goHome(guardGate = false, inMultiWindow = false))
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
