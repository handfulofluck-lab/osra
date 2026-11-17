package com.familyshield.agent.telemetry

import org.junit.Assert.assertEquals
import org.junit.Test

/**
 * Issue #867: the boot instant is `now - elapsedRealtime`, and the server's whole restart detection
 * rests on this one property — the same boot yields the same instant, a restart yields a different one.
 *
 * The values are fixed instants rather than a real clock: the failure this guards against is arithmetic
 * (a sign flipped, or the two clocks subtracted the wrong way round), which a live clock would hide.
 */
class BootClockTest {

    /** 2026-11-17T09:12:44Z, to the second. */
    private val now = 1_794_906_764_000L

    @Test
    fun `boot instant is now minus the time since boot`() {
        // Five minutes of uptime: the phone booted five minutes before "now".
        assertEquals("2026-11-17T09:07:44Z", BootClock.bootedAtIso(now, 5 * 60_000))
    }

    @Test
    fun `two ticks inside one boot report the same instant`() {
        // The two clocks advance together, so an upload fifteen minutes later names the same boot.
        val first = BootClock.bootedAtIso(now, 5 * 60_000)
        val second = BootClock.bootedAtIso(now + 15 * 60_000, 20 * 60_000)
        assertEquals(first, second)
    }

    @Test
    fun `a restart moves the reported instant`() {
        val beforeRestart = BootClock.bootedAtIso(now, 5 * 60_000)
        // After the reboot, uptime restarts near zero while the wall clock kept going.
        val afterRestart = BootClock.bootedAtIso(now + 2 * 60_000, 30_000)
        assertEquals("2026-11-17T09:14:14Z", afterRestart)
        assertEquals(false, beforeRestart == afterRestart)
    }

    @Test
    fun `deep sleep counts as uptime, so a long-idle phone still reports its own boot`() {
        // Eleven days of uptime: elapsedRealtime includes deep sleep, and the subtraction still lands on
        // a real boot instant rather than drifting forward each time the screen was off.
        val elevenDays = 11L * 24 * 60 * 60 * 1000
        val iso = BootClock.bootedAtIso(now, elevenDays)
        assertEquals("2026-11-06T09:12:44Z", iso)
    }

    @Test
    fun `whole seconds only, and UTC`() {
        val iso = BootClock.bootedAtIso(now + 999, 0)
        assertEquals("2026-11-17T09:12:44Z", iso)
        assertEquals(true, iso.endsWith("Z"))
        assertEquals(false, iso.contains("."))
    }
}
