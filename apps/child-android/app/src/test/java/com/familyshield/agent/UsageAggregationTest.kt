package com.familyshield.agent

import com.familyshield.agent.data.db.UsageEventEntity
import com.familyshield.agent.telemetry.computePerAppMinutes
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/** Pure-JVM tests for the telemetry event-stream aggregation (gap capping, window tail). */
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
        assertEquals(mapOf("com.a" to 5, "com.b" to 5), perApp)
    }

    @Test
    fun `gaps longer than five minutes are capped`() {
        val events = listOf(ev("com.a", 0L), ev("com.b", 60 * 60_000L))
        val perApp = computePerAppMinutes(events, windowEnd = 61 * 60_000L)
        assertEquals(5, perApp["com.a"])
        assertEquals(1, perApp["com.b"])
    }

    @Test
    fun `last event earns the tail up to windowEnd`() {
        val perApp = computePerAppMinutes(listOf(ev("com.a", 0L)), windowEnd = 4 * 60_000L)
        assertEquals(mapOf("com.a" to 4), perApp)
    }

    @Test
    fun `empty stream yields an empty map`() {
        assertTrue(computePerAppMinutes(emptyList(), windowEnd = 60_000L).isEmpty())
    }

    @Test
    fun `sub-minute and negative gaps credit nothing`() {
        val events = listOf(ev("com.a", 10 * 60_000L), ev("com.b", 5 * 60_000L)) // out of order
        val perApp = computePerAppMinutes(events, windowEnd = 5 * 60_000L + 30_000L)
        assertTrue(perApp.isEmpty())
    }
}
