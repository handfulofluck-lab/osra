package com.familyshield.agent.comms

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

/**
 * Issue #257 review: two defects the phone run found in the first watermark reset.
 *
 * 1. A pause that began and ended between two 5-minute ticks was never recorded, so the paused-window
 *    rows were read after the re-grant (privacy).
 * 2. The reset ran at the first harvest after the re-grant, which read nothing and dropped the call
 *    that triggered it (data loss).
 *
 * Both are timing between `ConsentState` and the harvest, which is exactly the gap this repo's JUnit
 * harness cannot execute — but the decision table can be pinned, and Claude's four cases are below.
 */
class CommsConsentPolicyTest {

    private val resumedAt = 1_700_000_123_000L

    @Test
    fun `nothing changes when the epoch is the one already applied`() {
        assertNull(
            "a steady state must not touch the watermarks",
            CommsConsentPolicy.resetTo(storedEpoch = 2L, epoch = 2L, paused = false, resumedAtMs = resumedAt),
        )
    }

    @Test
    fun `a first run or an upgrade never resets`() {
        // No stored epoch and no withdrawal: reading history here would be the #229 import.
        assertNull(CommsConsentPolicy.resetTo(storedEpoch = null, epoch = 0L, paused = false, resumedAtMs = resumedAt))
    }

    @Test
    fun `a pause between ticks still resets at the re-grant time`() {
        val from = CommsConsentPolicy.resetTo(storedEpoch = null, epoch = 1L, paused = false, resumedAtMs = resumedAt)

        assertEquals("the withdrawal is recorded even when no harvest saw it paused", resumedAt, from)
    }

    @Test
    fun `the first call after a re-grant is read, because the reset starts at the re-grant time`() {
        // The call that triggers the first look is newer than resumedAtMs, so starting there reads it
        // rather than skipping to "now".
        val from = CommsConsentPolicy.resetTo(storedEpoch = 0L, epoch = 3L, paused = false, resumedAtMs = resumedAt)

        assertEquals(resumedAt, from)
    }

    @Test
    fun `a paused device defers the reset to the re-grant`() {
        assertNull(
            "restarting into a paused window would collect nothing and lose the epoch comparison",
            CommsConsentPolicy.resetTo(storedEpoch = 1L, epoch = 2L, paused = true, resumedAtMs = resumedAt),
        )
    }
}
