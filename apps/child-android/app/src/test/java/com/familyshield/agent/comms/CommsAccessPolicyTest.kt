package com.familyshield.agent.comms

import org.junit.Assert.assertEquals
import org.junit.Test

/** Issue #91: the harvest gate is a decision, and the "say it once" part is testable without Android. */
class CommsAccessPolicyTest {

    @Test
    fun `permission granted always harvests, reported or not`() {
        assertEquals(CommsAccessPolicy.Decision.HARVEST, CommsAccessPolicy.decide(hasPermission = true, alreadyReported = false))
        assertEquals(CommsAccessPolicy.Decision.HARVEST, CommsAccessPolicy.decide(hasPermission = true, alreadyReported = true))
    }

    @Test
    fun `the first missing-permission attempt reports, later ones stay quiet`() {
        assertEquals(CommsAccessPolicy.Decision.SKIP_AND_REPORT, CommsAccessPolicy.decide(hasPermission = false, alreadyReported = false))
        assertEquals(CommsAccessPolicy.Decision.SKIP_QUIETLY, CommsAccessPolicy.decide(hasPermission = false, alreadyReported = true))
    }

    @Test
    fun `the quiet state is per process, so a fresh flag reports again`() {
        // What the logger does after the first report: it flips the flag. A new process starts unset, which
        // is the intended behaviour — one line per launch, never one per event.
        var reported = false
        val first = CommsAccessPolicy.decide(hasPermission = false, alreadyReported = reported)
        if (first == CommsAccessPolicy.Decision.SKIP_AND_REPORT) reported = true
        val second = CommsAccessPolicy.decide(hasPermission = false, alreadyReported = reported)
        assertEquals(CommsAccessPolicy.Decision.SKIP_AND_REPORT, first)
        assertEquals(CommsAccessPolicy.Decision.SKIP_QUIETLY, second)
    }
}
