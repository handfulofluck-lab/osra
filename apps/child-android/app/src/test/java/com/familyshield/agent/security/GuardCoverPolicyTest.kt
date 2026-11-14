package com.familyshield.agent.security

import com.familyshield.agent.enforcement.WindowBounds
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * osra-security#7: the cover over a protection screen that shares the screen. Rows for split screen, a pop-up
 * over the full-screen gate, a pop-up over Home, the single-window case the gate already handles, grace and no
 * PIN.
 */
class GuardCoverPolicyTest {

    private val topHalf = WindowBounds(0, 0, 1080, 1170)
    private val bottomHalf = WindowBounds(0, 1190, 1080, 2340)
    private val fullScreen = WindowBounds(0, 0, 1080, 2340)
    private val popUp = WindowBounds(120, 600, 960, 1500)

    @Test
    fun `split screen covers the half with the protection screen`() {
        val windows = listOf(GuardWindow(protected = true, bounds = topHalf), GuardWindow(false, bottomHalf))
        assertEquals(topHalf, GuardCoverPolicy.cover(windows, guardActive = true))
    }

    @Test
    fun `a pop-up over the full-screen gate is covered, the gate is not`() {
        val windows = listOf(GuardWindow(false, fullScreen), GuardWindow(true, popUp))
        assertEquals(popUp, GuardCoverPolicy.cover(windows, guardActive = true))
    }

    @Test
    fun `a pop-up over Home is covered`() {
        val windows = listOf(GuardWindow(true, popUp), GuardWindow(false, fullScreen))
        assertEquals(popUp, GuardCoverPolicy.cover(windows, guardActive = true))
    }

    @Test
    fun `one full-screen window gets no cover, the gate opens over it`() {
        assertNull(GuardCoverPolicy.cover(listOf(GuardWindow(true, fullScreen)), guardActive = true))
    }

    @Test
    fun `a full-screen protection screen under the gate coming up gets no cover`() {
        val windows = listOf(GuardWindow(true, fullScreen), GuardWindow(false, fullScreen))
        assertNull(GuardCoverPolicy.cover(windows, guardActive = true))
    }

    @Test
    fun `no cover in grace or without a PIN`() {
        val windows = listOf(GuardWindow(true, topHalf), GuardWindow(false, bottomHalf))
        assertNull(GuardCoverPolicy.cover(windows, guardActive = false))
    }

    @Test
    fun `no cover when no window is a protection screen`() {
        assertNull(GuardCoverPolicy.cover(listOf(GuardWindow(false, topHalf), GuardWindow(false, bottomHalf)), true))
    }

    @Test
    fun `two protection windows are covered together, and empty or unknown bounds are skipped`() {
        val windows = listOf(
            GuardWindow(true, popUp), GuardWindow(true, WindowBounds(200, 1600, 900, 2000)),
            GuardWindow(true, null), GuardWindow(true, WindowBounds(5, 5, 5, 5)), GuardWindow(false, fullScreen),
        )
        assertEquals(WindowBounds(120, 600, 960, 2000), GuardCoverPolicy.cover(windows, guardActive = true))
        assertNull(GuardCoverPolicy.cover(listOf(GuardWindow(true, null), GuardWindow(false, fullScreen)), true))
    }

    @Test
    fun `the gate is launched once, when the cover goes up`() {
        assertTrue(GuardCoverPolicy.stepIn(null, topHalf))
        assertFalse(GuardCoverPolicy.stepIn(topHalf, topHalf))
        assertFalse(GuardCoverPolicy.stepIn(topHalf, popUp))
        assertFalse(GuardCoverPolicy.stepIn(topHalf, null))
        assertFalse(GuardCoverPolicy.stepIn(null, null))
    }
}
