package com.familyshield.agent.receivers

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * osra-security#29/#30 review (Claude and Antigravity): the two decisions that reach the parent.
 *
 * They are pure on purpose. The rows that used to cover this only read the service's source, so deleting the
 * `paired && outside grace` check or the latch's assignment failed no test — the criticism landed on three of my
 * rows in one night, and this is the shape that answers it.
 *
 * Mutants: drop `paired &&` → [an unpaired phone tells nobody]; drop `nowMs >= graceUntilMs` → [a parent's own
 * switch-off inside the grace window is not paged]; latch granted always → [the latch is taken from the grant on
 * entry]; never clear → [another window clears the latch]; clear on an unnamed window → [an unnamed window leaves
 * the latch alone].
 */
class AccessibilityOffPolicyTest {

    @Test
    fun `a paired phone outside the grace window tells the parent`() {
        assertTrue(AccessibilityOffPolicy.shouldTellParent(paired = true, graceUntilMs = 0L, nowMs = 1_000L))
    }

    @Test
    fun `an unpaired phone tells nobody`() {
        assertFalse(AccessibilityOffPolicy.shouldTellParent(paired = false, graceUntilMs = 0L, nowMs = 1_000L))
    }

    /** osra-security#29's U2a: the parent's own PIN-approved switch-off is recorded, not paged. */
    @Test
    fun `a parent's own switch-off inside the grace window is not paged`() {
        assertFalse(AccessibilityOffPolicy.shouldTellParent(paired = true, graceUntilMs = 10_000L, nowMs = 5_000L))
        assertTrue("and the grace window ends", AccessibilityOffPolicy.shouldTellParent(true, 10_000L, 10_000L))
    }

    @Test
    fun `the latch is taken from the grant on entry`() {
        assertEquals(
            true,
            AccessibilityOffPolicy.nextLatch(previous = null, packageName = "com.android.permissioncontroller") { true },
        )
        assertEquals(
            false,
            AccessibilityOffPolicy.nextLatch(previous = null, packageName = "com.google.android.permissioncontroller") { false },
        )
    }

    /** Granting inside the page must not change the decision mid-visit: the entry value wins. */
    @Test
    fun `the latch keeps its entry value for the whole visit`() {
        assertEquals(
            false,
            AccessibilityOffPolicy.nextLatch(previous = false, packageName = "com.android.permissioncontroller") { true },
        )
    }

    @Test
    fun `another window clears the latch`() {
        assertNull(
            AccessibilityOffPolicy.nextLatch(previous = true, packageName = "com.android.settings") { true },
        )
    }

    @Test
    fun `an unnamed window leaves the latch alone`() {
        assertEquals(true, AccessibilityOffPolicy.nextLatch(previous = true, packageName = null) { false })
    }
}
