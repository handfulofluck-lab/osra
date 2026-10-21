package com.familyshield.agent.comms

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Issue #229: the first harvest imported the phone's whole call history (1,986 rows back to
 * 2026-01-23 on the Flip4) because the watermark fell back to `0L` and the query was `DATE > 0`.
 *
 * The rule: collection starts when it is allowed, never before. The pure decision is held here; the
 * caller (`CommsLogger.harvestCalls` / `harvestSms`) is pinned by [CommsGrantWiringTest], because it
 * needs Android and Room and cannot run in this suite.
 */
class CommsWatermarkPolicyTest {

    @Test
    fun `no watermark means nothing is read and collection starts now`() {
        val now = 1_760_000_000_000L

        assertTrue(CommsWatermarkPolicy.isFirstHarvest(CommsWatermarkPolicy.normalize(null)))
        assertNull(
            "a null watermark must not become a query lower bound of 0",
            CommsWatermarkPolicy.startFrom(CommsWatermarkPolicy.normalize(null), null),
        )
        assertEquals(
            "the first allowed harvest records its own start time",
            now,
            CommsWatermarkPolicy.initialWatermark(CommsWatermarkPolicy.normalize(null), now),
        )
    }

    @Test
    fun `the old 0L default is the same as no watermark`() {
        assertNull(CommsWatermarkPolicy.normalize(0L))
        assertNull(CommsWatermarkPolicy.normalize(-1L))
        assertEquals(1L, CommsWatermarkPolicy.normalize(1L))
        assertEquals(42L, CommsWatermarkPolicy.normalize(42L))
    }

    @Test
    fun `a stored watermark is kept and is the read floor`() {
        val stored = 1_759_000_000_000L

        assertFalse(CommsWatermarkPolicy.isFirstHarvest(CommsWatermarkPolicy.normalize(stored)))
        assertEquals("a later harvest keeps the stored value", stored, CommsWatermarkPolicy.initialWatermark(stored, 1_760_000_000_000L))
        assertEquals(stored, CommsWatermarkPolicy.startFrom(stored, grantTime = null))
    }

    @Test
    fun `a re-grant floors the read at the grant time, even if a stale watermark survived`() {
        val stale = 1_759_000_000_000L
        val regrant = 1_760_000_000_000L

        assertEquals("the grant is later than the stale watermark", regrant, CommsWatermarkPolicy.startFrom(stale, regrant))
        val past = regrant + 60_000L
        assertEquals(
            "a watermark already past the grant is not moved backwards",
            past,
            CommsWatermarkPolicy.startFrom(past, regrant),
        )
    }
}
