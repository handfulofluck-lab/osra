package com.familyshield.agent.sos

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Issue #672 review (Fable, note 1): the SOS screen starts `LocationService` with `ACTION_PING_NOW` from the
 * resumed activity, so the background-start policy does not apply — but an unpaired phone must not ask for a
 * fix nobody can see. One row per pair of inputs.
 *
 * Mutants: `return hasLocationPermission` → [an unpaired phone asks for no fix]; `return isPaired` →
 * [a phone without a location grant asks for none].
 */
class SosFreshFixPolicyTest {

    @Test
    fun `a paired phone with a location grant asks for a fresh fix`() {
        assertTrue(SosFreshFixPolicy.shouldRequest(isPaired = true, hasLocationPermission = true))
    }

    @Test
    fun `an unpaired phone asks for no fix`() {
        assertFalse(
            "the fix would have no reader, and an FGS location notification would sit on a phone nobody manages",
            SosFreshFixPolicy.shouldRequest(isPaired = false, hasLocationPermission = true),
        )
    }

    @Test
    fun `a phone without a location grant asks for no fix`() {
        assertFalse(SosFreshFixPolicy.shouldRequest(isPaired = true, hasLocationPermission = false))
    }

    @Test
    fun `neither asks for anything`() {
        assertFalse(SosFreshFixPolicy.shouldRequest(isPaired = false, hasLocationPermission = false))
    }
}
