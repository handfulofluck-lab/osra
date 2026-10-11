package com.familyshield.agent

import com.familyshield.agent.data.UsageCounters
import java.time.LocalDate
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/** Pure-JVM tests for the daily usage counters (extracted from RuleRepository). */
class UsageCountersTest {

    private val day1: LocalDate = LocalDate.of(2026, 9, 14)
    private val day2: LocalDate = day1.plusDays(1)

    @Test
    fun `elapsed minutes are credited to the previous package`() {
        val c = UsageCounters()
        c.onForegroundEvent("com.a", 0L, day1)
        c.onForegroundEvent("com.b", 3 * 60_000L, day1)
        assertEquals(mapOf("com.a" to 3), c.snapshot(3 * 60_000L, day1))
    }

    @Test
    fun `gaps longer than five minutes are capped`() {
        val c = UsageCounters()
        c.onForegroundEvent("com.a", 0L, day1)
        c.onForegroundEvent("com.b", 30 * 60_000L, day1)
        assertEquals(mapOf("com.a" to 5), c.snapshot(30 * 60_000L, day1))
    }

    @Test
    fun `snapshot credits in-progress foreground time without double counting`() {
        val c = UsageCounters()
        c.onForegroundEvent("com.a", 0L, day1)
        // In-progress credit: 2 min not yet "stored".
        assertEquals(mapOf("com.a" to 2), c.snapshot(2 * 60_000L, day1))
        // The snapshot must not persist the credit: the next event re-measures from the same mark.
        c.onForegroundEvent("com.b", 2 * 60_000L, day1)
        assertEquals(mapOf("com.a" to 2), c.snapshot(2 * 60_000L, day1))
    }

    @Test
    fun `sub-minute gaps and backwards clocks credit zero minutes`() {
        val c = UsageCounters()
        c.onForegroundEvent("com.a", 10_000L, day1)
        c.onForegroundEvent("com.b", 5_000L, day1) // clock went backwards
        c.onForegroundEvent("com.c", 45_000L, day1) // sub-minute gap
        assertTrue(c.snapshot(45_000L, day1).isEmpty())
    }

    @Test
    fun `counters reset when the date rolls over midnight`() {
        val c = UsageCounters()
        c.onForegroundEvent("com.a", 0L, day1)
        c.onForegroundEvent("com.b", 3 * 60_000L, day1)
        assertEquals(mapOf("com.a" to 3), c.snapshot(3 * 60_000L, day1))
        // After midnight the counters (and the in-progress app) are cleared.
        assertTrue(c.snapshot(4 * 60_000L, day2).isEmpty())
        // New day accumulates from zero.
        c.onForegroundEvent("com.c", 5 * 60_000L, day2)
        assertEquals(mapOf("com.c" to 2), c.snapshot(7 * 60_000L, day2))
    }

    @Test
    fun `resetIfNewDay is a no-op within the same day`() {
        val c = UsageCounters()
        c.onForegroundEvent("com.a", 0L, day1)
        c.onForegroundEvent("com.b", 4 * 60_000L, day1)
        c.resetIfNewDay(day1)
        assertEquals(mapOf("com.a" to 4), c.snapshot(4 * 60_000L, day1))
    }

    @Test
    fun `explicit resetIfNewDay clears counters on the new day`() {
        val c = UsageCounters()
        c.onForegroundEvent("com.a", 0L, day1)
        c.onForegroundEvent("com.b", 4 * 60_000L, day1)
        c.resetIfNewDay(day2)
        assertTrue(c.snapshot(4 * 60_000L, day2).isEmpty())
    }

    @Test
    fun `rebuildFromEvents restores per-app minutes from chronological transitions`() {
        val c = UsageCounters()
        val events = listOf(
            "com.game" to 0L,
            "com.social" to 10 * 60_000L,
            "com.game" to 15 * 60_000L,
            "com.idle" to 20 * 60_000L,
        )
        c.rebuildFromEvents(events, day1)
        val snap = c.snapshot(20 * 60_000L, day1)
        // com.game ran 0..10 (capped at 5) + 15..20 (5) = 10
        // com.social ran 10..15 (5) = 5
        assertEquals(10, snap["com.game"])
        assertEquals(5, snap["com.social"])
    }

    @Test
    fun `restore populates per-app minutes and respects day boundaries`() {
        val c = UsageCounters()
        c.restore(mapOf("com.game" to 45, "com.youtube" to 30), day1)
        assertEquals(mapOf("com.game" to 45, "com.youtube" to 30), c.snapshot(0L, day1))
        // Rolling over to next day resets the restored counters
        assertTrue(c.snapshot(0L, day2).isEmpty())
    }
}
