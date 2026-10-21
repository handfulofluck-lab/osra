package com.familyshield.agent

import com.familyshield.agent.data.db.UsageEventEntity
import com.familyshield.agent.telemetry.computePerAppMinutes
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/** Pure-JVM tests for the telemetry event-stream aggregation (gap capping, window tail, carry). */
class UsageAggregationTest {

    private fun ev(pkg: String, tsMs: Long) = UsageEventEntity(packageId = pkg, timestamp = tsMs)

    @Test
    fun `gaps are converted to whole minutes per app`() {
        val events = listOf(
            ev("com.a", 0L),
            ev("com.b", 3 * 60_000L),
            ev("com.a", 10 * 60_000L),
        )
        val perApp = computePerAppMinutes(events, windowEnd = 12 * 60_000L)
        // a: 3 min (0→3) + 2 min (10→12 tail); b: 7 min capped to 5.
        assertEquals(mapOf("com.a" to 5, "com.b" to 5), perApp.minutes)
    }

    @Test
    fun `gaps longer than five minutes are capped`() {
        val events = listOf(ev("com.a", 0L), ev("com.b", 60 * 60_000L))
        val perApp = computePerAppMinutes(events, windowEnd = 61 * 60_000L)
        assertEquals(5, perApp.minutes["com.a"])
        assertEquals(1, perApp.minutes["com.b"])
    }

    @Test
    fun `last event earns the tail up to windowEnd`() {
        val perApp = computePerAppMinutes(listOf(ev("com.a", 0L)), windowEnd = 4 * 60_000L)
        assertEquals(mapOf("com.a" to 4), perApp.minutes)
    }

    @Test
    fun `empty stream yields an empty map`() {
        val perApp = computePerAppMinutes(emptyList(), windowEnd = 60_000L)
        assertTrue(perApp.minutes.isEmpty())
        assertTrue(perApp.remainderMs.isEmpty())
    }

    @Test
    fun `sub-minute and negative gaps credit nothing`() {
        val events = listOf(ev("com.a", 10 * 60_000L), ev("com.b", 5 * 60_000L)) // out of order
        val perApp = computePerAppMinutes(events, windowEnd = 5 * 60_000L + 30_000L)
        assertTrue(perApp.minutes.isEmpty())
        // The 30 s tail is not lost — it is carried into the next window (#276).
        assertEquals(mapOf("com.b" to 30_000L), perApp.remainderMs)
    }

    @Test
    fun `sixteen status-bar events yield fifteen minutes and carry the rest`() {
        val step = 59_900L
        val events = (0 until 16).map { ev("com.video", it * step) }
        val perApp = computePerAppMinutes(events, windowEnd = 16 * step)
        assertEquals(mapOf("com.video" to 15), perApp.minutes)
        assertEquals(mapOf("com.video" to 58_400L), perApp.remainderMs)
    }

    @Test
    fun `two consecutive windows with the carry sum to the same total as one window`() {
        val step = 59_900L
        val events = (0 until 16).map { ev("com.video", it * step) }
        val whole = computePerAppMinutes(events, windowEnd = 16 * step)
        val first = computePerAppMinutes(events.take(8), windowEnd = 8 * step)
        val second = computePerAppMinutes(events.drop(8), windowEnd = 16 * step, carriedMs = first.remainderMs)
        assertEquals(15, whole.minutes["com.video"])
        assertEquals(7, first.minutes["com.video"])
        assertEquals(8, second.minutes["com.video"])
        assertEquals(whole.remainderMs["com.video"], second.remainderMs["com.video"])
    }

    @Test
    fun `two sub-minute windows still make a minute`() {
        val first = computePerAppMinutes(listOf(ev("com.a", 0L)), windowEnd = 30_000L)
        assertTrue(first.minutes.isEmpty())
        val second = computePerAppMinutes(listOf(ev("com.a", 60_000L)), windowEnd = 90_000L, carriedMs = first.remainderMs)
        assertEquals(mapOf("com.a" to 1), second.minutes)
    }

    @Test
    fun `a sub-minute event package is mentioned, a carried-only package is not`() {
        // Review R1 on #281: the backfill skips the packages the window's events mentioned even when they
        // produced no whole minute, and must still add Android's increase for a package that only carries
        // a remainder — that time was already in the previous upload's snapshot.
        val window = computePerAppMinutes(
            listOf(ev("com.a", 0L)),
            windowEnd = 40_000L,
            carriedMs = mapOf("com.b" to 30_000L),
        )
        assertTrue(window.minutes.isEmpty())
        assertEquals(mapOf("com.a" to 40_000L, "com.b" to 30_000L), window.remainderMs)
        assertEquals(setOf("com.a"), window.eventPackages)
    }
}
