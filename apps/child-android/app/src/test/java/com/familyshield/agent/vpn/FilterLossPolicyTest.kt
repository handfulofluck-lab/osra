package com.familyshield.agent.vpn

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class FilterLossPolicyTest {
    @Test
    fun `the first eligible revoke of an established filter creates one incident`() {
        // Mutant: ignore recordedEpoch, so repeat callbacks produce more alerts.
        assertTrue(shouldRecord(recordedEpoch = null, consentEpoch = 0))
        assertFalse(shouldRecord(recordedEpoch = 0, consentEpoch = 0))
        assertTrue(isLost(recordedEpoch = 0, consentEpoch = 0))
    }

    @Test
    fun `setup disabled protection and withdrawn consent never begin an incident`() {
        // Mutant: drop any prerequisite, so that row records a revocation.
        assertFalse(shouldRecord(wasEstablished = false))
        assertFalse(shouldRecord(enabled = false))
        assertFalse(shouldRecord(paired = false))
        assertFalse(shouldRecord(consentPaused = true))
    }

    @Test
    fun `a stored incident only applies during its own active consent period`() {
        // Mutant: drop the epoch comparison, so a pause and re-grant resurrect an incident.
        assertTrue(isLost(recordedEpoch = 3, consentEpoch = 3))
        assertFalse(isLost(recordedEpoch = 3, consentEpoch = 4))
        assertTrue(shouldRecord(recordedEpoch = 3, consentEpoch = 4))
        assertFalse(isLost(recordedEpoch = 3, consentEpoch = 3, consentPaused = true))
        assertFalse(isLost(recordedEpoch = 3, consentEpoch = 3, paired = false))
        assertFalse(isLost(recordedEpoch = 3, consentEpoch = 3, enabled = false))
        assertFalse(isLost(recordedEpoch = null, consentEpoch = 0))
    }

    private fun shouldRecord(
        recordedEpoch: Long? = null,
        wasEstablished: Boolean = true,
        enabled: Boolean = true,
        paired: Boolean = true,
        consentPaused: Boolean = false,
        consentEpoch: Long = 0,
    ): Boolean = FilterLossPolicy.shouldRecord(recordedEpoch, wasEstablished, enabled, paired, consentPaused, consentEpoch)

    private fun isLost(
        recordedEpoch: Long?,
        consentEpoch: Long,
        enabled: Boolean = true,
        paired: Boolean = true,
        consentPaused: Boolean = false,
    ): Boolean = FilterLossPolicy.isLost(recordedEpoch, enabled, paired, consentPaused, consentEpoch)
}
