package com.familyshield.agent.commands

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/** Plan 1.7: who may stop a ring, and which fix a locate_now reports. */
class RingAndLocatePolicyTest {

    @Test
    fun `only the parent's PIN, a parent command or the cap stop a ring`() {
        assertTrue(RingPolicy.stopAllowed(RingPolicy.StopSource.PIN_VERIFIED))
        assertTrue(RingPolicy.stopAllowed(RingPolicy.StopSource.PARENT_COMMAND))
        assertTrue(RingPolicy.stopAllowed(RingPolicy.StopSource.TIMEOUT))
        assertFalse(RingPolicy.stopAllowed(RingPolicy.StopSource.CHILD_BACK))
        assertFalse(RingPolicy.stopAllowed(RingPolicy.StopSource.CHILD_VOLUME_KEY))
        assertFalse(RingPolicy.stopAllowed(RingPolicy.StopSource.SCREEN_OFF))
    }

    @Test
    fun `ring runs at the stream maximum and the cap is five minutes`() {
        assertEquals(15, RingPolicy.ringVolume(15))
        assertEquals(1, RingPolicy.ringVolume(0))
        assertEquals(5 * 60 * 1000L, RingPolicy.MAX_RING_MS)
    }

    @Test
    fun `volume is restored only when nobody touched it during the ring`() {
        assertEquals(3, RingPolicy.restoreVolume(previous = 3, current = 15, ringLevel = 15))
        assertEquals(7, RingPolicy.restoreVolume(previous = 3, current = 7, ringLevel = 15))
    }

    @Test
    fun `locate prefers a fresh fix, falls back to a recent cached one, reports nothing for a stale one`() {
        val now = 1_000_000L
        assertEquals(LocatePolicy.Choice.FRESH, LocatePolicy.choose(freshAvailable = true, cachedTimeMs = now - 60_000, nowMs = now))
        assertEquals(LocatePolicy.Choice.CACHED, LocatePolicy.choose(freshAvailable = false, cachedTimeMs = now - 60_000, nowMs = now))
        assertEquals(LocatePolicy.Choice.NONE, LocatePolicy.choose(freshAvailable = false, cachedTimeMs = now - 6 * 60_000, nowMs = now))
        assertEquals(LocatePolicy.Choice.NONE, LocatePolicy.choose(freshAvailable = false, cachedTimeMs = null, nowMs = now))
        assertEquals(30_000L, LocatePolicy.FRESH_FIX_TIMEOUT_MS)
    }
}
