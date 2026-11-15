package com.familyshield.agent.receivers

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import com.familyshield.agent.security.TamperScreenPolicy
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

    /**
     * Claude's row: a switch-off stamped **inside** the grace window, and a poll that lands **after** it. The decision
     * reads the stamped moment, not the clock, so the parent is not paged for their own switch-off — and the row goes
     * red if `eventTimeMs` ignores the stamp.
     */
    @Test
    fun `a switch-off stamped inside grace is still inside grace when the poll runs later`() {
        val stampedAt = 1_000L
        val nowAfterGrace = 10_000L
        val graceUntil = 5_000L
        val eventAt = AccessibilityOffPolicy.eventTimeMs(stampedAt, nowAfterGrace)
        assertEquals("the stamped moment wins", stampedAt, eventAt)
        assertFalse(
            "and the parent is not paged after the window for their own switch-off",
            AccessibilityOffPolicy.shouldTellParent(paired = true, graceUntilMs = graceUntil, nowMs = eventAt),
        )
        // The same poll with no stamp reads the clock and does page: that is the case the stamp exists for.
        assertTrue(
            AccessibilityOffPolicy.shouldTellParent(
                paired = true,
                graceUntilMs = graceUntil,
                nowMs = AccessibilityOffPolicy.eventTimeMs(0L, nowAfterGrace),
            ),
        )
    }

    /**
     * Antigravity's item 3: the special-access latch is captured on entering Settings, held for the visit, and
     * dropped when Settings is left — **including** when the next window is our own, which is what a Back from the
     * grant page produces.
     */
    @Test
    fun `the special-access latch is captured on entry, held, and dropped on leaving`() {
        val heldNow = setOf(TamperScreenPolicy.SpecialAccess.OVERLAY)
        fun next(previous: Set<TamperScreenPolicy.SpecialAccess>?, pkg: String?) =
            AccessibilityOffPolicy.nextSpecialAccessLatch(
                previous = previous,
                packageName = pkg,
                settingsPackage = "com.android.settings",
                ourPackage = "com.familyshield.agent",
                heldNow = { heldNow },
            )

        assertEquals("captured on entry", heldNow, next(null, "com.android.settings"))
        // Held for the whole visit: a grant made inside it does not change the decision.
        assertEquals("held for the visit", heldNow, next(heldNow, "com.android.settings"))
        assertEquals("an unnamed window keeps it", heldNow, next(heldNow, null))
        assertNull("leaving Settings drops it", next(heldNow, "com.android.telephony"))
        assertNull("and so does coming back to us after a grant", next(heldNow, "com.familyshield.agent"))
    }
}
