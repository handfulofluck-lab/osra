package com.familyshield.agent.security

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * #792 / Codex's finding: the error banner's colour measured 2.37:1 against the gate's background, below the
 * 4.5:1 the Bureau holds normal text to. The colour moved; this keeps it moved.
 *
 * The mutants are the two obvious reverts — put `0xFFB00020` back, or lighten the background until the ratio
 * only just passes — and both are arithmetic, so the row does not need a phone or a screenshot.
 */
class GuardPaletteTest {

    @Test
    fun `the old error colour is below the floor, which is why it moved`() {
        // Kept as a row so the next person sees the measurement rather than a claim about 2.37:1.
        assertEquals(2.37, GuardPalette.contrastRatio(0xFFB00020.toInt(), GuardPalette.BACKGROUND), 0.01)
        assertTrue(GuardPalette.contrastRatio(0xFFB00020.toInt(), GuardPalette.BACKGROUND) < GuardPalette.MIN_BODY_CONTRAST)
    }

    @Test
    fun `the served error text clears the floor with room`() {
        val ratio = GuardPalette.contrastRatio(GuardPalette.ERROR_TEXT, GuardPalette.BACKGROUND)
        assertTrue("ratio was $ratio", ratio >= GuardPalette.MIN_BODY_CONTRAST)
        // A ship-time margin, not a target: a later "small" tweak that lands at 4.6 would still pass the
        // floor and be invisible to review, so this row asks for the room the palette actually has.
        assertTrue("ratio was $ratio", ratio >= 7.0)
    }

    @Test
    fun `the contrast formula is the WCAG one, on its published anchors`() {
        // Black on white is 21:1 and a colour against itself is 1:1; if the formula drifts, these fail first.
        assertEquals(21.0, GuardPalette.contrastRatio(0xFF000000.toInt(), 0xFFFFFFFF.toInt()), 0.01)
        assertEquals(1.0, GuardPalette.contrastRatio(GuardPalette.BACKGROUND, GuardPalette.BACKGROUND), 0.01)
    }
}
