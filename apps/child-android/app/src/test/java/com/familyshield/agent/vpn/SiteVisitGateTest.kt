package com.familyshield.agent.vpn

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * #830 gating: the two off-state rows Fable asked for, plus the exclusion and the flag-on control.
 * These are the mutants the verifier should plant: ignoring `siteNamesEnabled` on the phone (row 1
 * turns green) and ignoring `blocked` (row 2 turns red).
 */
class SiteVisitGateTest {

    @Test
    fun `flag off keeps an unblocked name on the phone`() {
        assertFalse(SiteVisitGate.shouldUpload(siteNamesEnabled = false, blocked = false))
    }

    @Test
    fun `a blocked attempt is not behind the flag`() {
        assertTrue(SiteVisitGate.shouldUpload(siteNamesEnabled = false, blocked = true))
    }

    @Test
    fun `flag on uploads an unblocked name`() {
        assertTrue(SiteVisitGate.shouldUpload(siteNamesEnabled = true, blocked = false))
    }

    @Test
    fun `an excluded host never uploads`() {
        assertFalse(SiteVisitGate.shouldUpload(siteNamesEnabled = true, blocked = true, excludedHost = true))
    }
}
