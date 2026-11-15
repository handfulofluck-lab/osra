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
    fun `the special-access latch keeps what was held on entry, not what is held now`() {
        val heldNow = setOf(TamperScreenPolicy.SpecialAccess.OVERLAY)
        fun next(previous: Set<TamperScreenPolicy.SpecialAccess>?, pkg: String?) =
            AccessibilityOffPolicy.nextSpecialAccessLatch(
                previous = previous,
                packageName = pkg,
                settingsPackage = "com.android.settings",
                heldNow = { heldNow },
            )

        assertEquals("captured on entry", heldNow, next(null, "com.android.settings"))
        // The row that would pass if the latch never latched: a previous set that differs from what is held now must
        // be what comes back. Claude's item 1 — `previous = heldNow` tested nothing.
        val heldBefore = setOf(TamperScreenPolicy.SpecialAccess.USAGE)
        assertEquals("held for the visit, even if the grant changes", heldBefore, next(heldBefore, "com.android.settings"))
        assertEquals("an unnamed window keeps it", heldBefore, next(heldBefore, null))
        assertNull("leaving Settings drops it", next(heldBefore, "com.android.telephony"))
    }

    /**
     * Antigravity's Flip4 pass (#817): the sequence that turned a held grant into "the parent is granting it". The
     * child opens the usage page, taps **Search apps**, and the soft keyboard emits a state change with the *IME's*
     * package. Read from the event, that window cleared the latch; the foreground application package keeps it.
     *
     * The second assertion is the old behaviour on purpose: it is why the first one matters.
     */
    @Test
    fun `a keyboard state change does not clear the special-access latch`() {
        val held = setOf(TamperScreenPolicy.SpecialAccess.USAGE)
        val latchPkg = AccessibilityOffPolicy.latchPackage("com.android.settings", "com.samsung.android.honeyboard")
        assertEquals("the page in front, not the keyboard", "com.android.settings", latchPkg)
        assertEquals(
            "a held grant stays a held grant",
            held,
            AccessibilityOffPolicy.nextSpecialAccessLatch(
                previous = held,
                packageName = latchPkg,
                settingsPackage = "com.android.settings",
                heldNow = { held },
            ),
        )
        assertNull(
            "and read from the event, as it was, the latch is cleared — the bug this row locks",
            AccessibilityOffPolicy.nextSpecialAccessLatch(
                previous = held,
                packageName = "com.samsung.android.honeyboard",
                settingsPackage = "com.android.settings",
                heldNow = { held },
            ),
        )
        // A window with no application behind it still falls back to the event's own package.
        assertEquals(
            "the fallback is the event's package",
            "com.android.settings",
            AccessibilityOffPolicy.latchPackage(null, "com.android.settings"),
        )
    }

}
