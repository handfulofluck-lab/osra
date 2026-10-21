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

    // ── Issue #260 ────────────────────────────────────────────────────────────────────────────────

    /**
     * The call-waiting case from the phone run: a 50-second call was answered during a 290-second one,
     * so the short call ends first (smaller `_ID`, later `DATE`) and the long call ends second (larger
     * `_ID`, earlier `DATE`). A `DATE` watermark set by the short call is past the long call's `DATE`,
     * which is why the long call was never read; by `_ID` it is simply the next row.
     */
    @Test
    fun `a call inserted after a newer-dated one is still read, because the watermark is an id`() {
        val shortCallId = 1_001L
        val longCallId = 1_002L
        val shortCallDate = 1_792_563_200_000L
        val longCallDate = shortCallDate - 290_000L

        assertTrue(
            "the long call has an older DATE than the watermark the short call set, but a higher _ID",
            longCallDate < shortCallDate && CommsWatermarkPolicy.shouldReadById(longCallId, shortCallId),
        )
        assertFalse(
            "a row at or below the stored id is not re-read every five minutes",
            CommsWatermarkPolicy.shouldReadById(shortCallId, shortCallId),
        )
        assertTrue("nothing read yet means every row is new", CommsWatermarkPolicy.shouldReadById(1L, null))
    }

    @Test
    fun `a clock set forward once is detected instead of silently stopping collection`() {
        val now = 1_792_563_200_000L
        val aYearAhead = now + 365L * 24 * 60 * 60 * 1000

        assertTrue("a watermark a year ahead means the clock moved back", CommsWatermarkPolicy.isClockBack(aYearAhead, now))
        assertFalse("the skew itself is tolerated", CommsWatermarkPolicy.isClockBack(now + CommsWatermarkPolicy.CLOCK_SKEW_MS, now))
        assertTrue("just past the skew is not", CommsWatermarkPolicy.isClockBack(now + CommsWatermarkPolicy.CLOCK_SKEW_MS + 1, now))
        assertFalse("no watermark is not a clock problem", CommsWatermarkPolicy.isClockBack(null, now))
    }

    @Test
    fun `a row dated in the future never becomes the watermark`() {
        val now = 1_792_563_200_000L
        val futureRow = now + 365L * 24 * 60 * 60 * 1000

        assertTrue(CommsWatermarkPolicy.isFutureRow(futureRow, now))
        assertFalse(CommsWatermarkPolicy.isFutureRow(now - 1_000L, now))
        assertEquals("the stored watermark is the newest honest row, never a future one",
            now - 1_000L, CommsWatermarkPolicy.nextWatermark(now - 1_000L, now))
        assertEquals("and never a time past now", now,
            CommsWatermarkPolicy.nextWatermark(futureRow, now))
    }

    @Test
    fun `a grant time in the future is re-anchored, not clamped at read time`() {
        // Clamping at read time does not work: `now` moves each harvest and the stored floor stays
        // ahead of it, so the call made two minutes ago is excluded again and again. The caller must
        // store `now` over the bad value, which is what isClockBack tells it to do.
        val now = 1_792_563_200_000L
        val yearAhead = now + 365L * 24 * 60 * 60 * 1000

        assertTrue("a grant time a year ahead must be re-anchored", CommsWatermarkPolicy.isClockBack(yearAhead, now))
        assertFalse("an honest grant time is left alone", CommsWatermarkPolicy.isClockBack(now - 90L * 24 * 60 * 60 * 1000, now))
        assertFalse("no grant time is not a clock problem", CommsWatermarkPolicy.isClockBack(null, now))
    }

    // ── Issue #264 (F2): the floor is a per-row decision ─────────────────────────────────────────

    @Test
    fun `a call that straddles the floor stays out, and one made with the clock set back is read`() {
        val floor = 1_792_563_200_000L
        // Normal: started after the grant.
        assertTrue(CommsWatermarkPolicy.shouldReadCall(floor + 60_000L, 30, floor))
        // Straddle: started before the floor, still running when consent came back -- it happened
        // through the pause, so ADR-0008 keeps it out.
        assertFalse(CommsWatermarkPolicy.shouldReadCall(floor - 60_000L, 300, floor))
        // Clock set back: its whole span is before the floor, but its id is above the watermark, which
        // only a set-back clock produces because rows are written when a call ends.
        assertTrue(CommsWatermarkPolicy.shouldReadCall(floor - 30L * 24 * 60 * 60 * 1000, 120, floor))
        // No floor (never granted through this build) reads everything the id watermark offers.
        assertTrue(CommsWatermarkPolicy.shouldReadCall(floor - 1_000L, 10, 0L))
    }

    @Test
    fun `the straddle tolerance is the clock skew, not a second window`() {
        val floor = 1_792_563_200_000L
        val durationSec = 60L
        val durationMs = durationSec * 1000L
        val skew = CommsWatermarkPolicy.CLOCK_SKEW_MS
        // Ends exactly at the floor: still a straddle (the skew is inclusive).
        assertFalse(CommsWatermarkPolicy.shouldReadCall(floor - durationMs, durationSec, floor))
        // Ends one millisecond inside the skew: still a straddle.
        assertFalse(CommsWatermarkPolicy.shouldReadCall(floor - durationMs - skew, durationSec, floor))
        // Ends one millisecond beyond the skew: its whole span is before the floor, so it is read.
        assertTrue(CommsWatermarkPolicy.shouldReadCall(floor - durationMs - skew - 1, durationSec, floor))
    }
}
