package com.familyshield.agent

import com.familyshield.agent.data.db.UsageEventEntity
import com.familyshield.agent.telemetry.computePerAppMinutes
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/** Pure-JVM tests for the telemetry event-stream aggregation (gap capping, window tail, carry). */
class UsageAggregationTest {

    private fun ev(pkg: String, tsMs: Long) = UsageEventEntity(packageId = pkg, timestamp = tsMs)

    /** The agent's own package — the block screen the child waits on (#284). */
    private val own = "com.familyshield.agent"

    @Test
    fun `gaps are converted to whole minutes per app`() {
        val events = listOf(
            ev("com.a", 0L),
            ev("com.b", 3 * 60_000L),
            ev("com.a", 10 * 60_000L),
        )
        val perApp = computePerAppMinutes(events, windowEnd = 12 * 60_000L, ownPackage = own)
        // a: 3 min (0→3) + 2 min (10→12 tail); b: 7 min capped to 5.
        assertEquals(mapOf("com.a" to 5, "com.b" to 5), perApp.minutes)
    }

    @Test
    fun `gaps longer than five minutes are capped`() {
        val events = listOf(ev("com.a", 0L), ev("com.b", 60 * 60_000L))
        val perApp = computePerAppMinutes(events, windowEnd = 61 * 60_000L, ownPackage = own)
        assertEquals(5, perApp.minutes["com.a"])
        assertEquals(1, perApp.minutes["com.b"])
    }

    @Test
    fun `last event earns the tail up to windowEnd`() {
        val perApp = computePerAppMinutes(listOf(ev("com.a", 0L)), windowEnd = 4 * 60_000L, ownPackage = own)
        assertEquals(mapOf("com.a" to 4), perApp.minutes)
    }

    @Test
    fun `empty stream yields an empty map`() {
        val perApp = computePerAppMinutes(emptyList(), windowEnd = 60_000L, ownPackage = own)
        assertTrue(perApp.minutes.isEmpty())
        assertTrue(perApp.remainderMs.isEmpty())
    }

    @Test
    fun `sub-minute and negative gaps credit nothing`() {
        val events = listOf(ev("com.a", 10 * 60_000L), ev("com.b", 5 * 60_000L)) // out of order
        val perApp = computePerAppMinutes(events, windowEnd = 5 * 60_000L + 30_000L, ownPackage = own)
        assertTrue(perApp.minutes.isEmpty())
        // The 30 s tail is not lost — it is carried into the next window (#276).
        assertEquals(mapOf("com.b" to 30_000L), perApp.remainderMs)
    }

    @Test
    fun `sixteen status-bar events yield fifteen minutes and carry the rest`() {
        val step = 59_900L
        val events = (0 until 16).map { ev("com.video", it * step) }
        val perApp = computePerAppMinutes(events, windowEnd = 16 * step, ownPackage = own)
        assertEquals(mapOf("com.video" to 15), perApp.minutes)
        assertEquals(mapOf("com.video" to 58_400L), perApp.remainderMs)
    }

    @Test
    fun `two consecutive windows with the carry sum to the same total as one window`() {
        val step = 59_900L
        val events = (0 until 16).map { ev("com.video", it * step) }
        val whole = computePerAppMinutes(events, windowEnd = 16 * step, ownPackage = own)
        val first = computePerAppMinutes(events.take(8), windowEnd = 8 * step, ownPackage = own)
        val second = computePerAppMinutes(events.drop(8), windowEnd = 16 * step, ownPackage = own, carriedMs = first.remainderMs)
        assertEquals(15, whole.minutes["com.video"])
        assertEquals(7, first.minutes["com.video"])
        assertEquals(8, second.minutes["com.video"])
        assertEquals(whole.remainderMs["com.video"], second.remainderMs["com.video"])
    }

    @Test
    fun `two sub-minute windows still make a minute`() {
        val first = computePerAppMinutes(listOf(ev("com.a", 0L)), windowEnd = 30_000L, ownPackage = own)
        assertTrue(first.minutes.isEmpty())
        val second = computePerAppMinutes(listOf(ev("com.a", 60_000L)), windowEnd = 90_000L, ownPackage = own, carriedMs = first.remainderMs)
        assertEquals(mapOf("com.a" to 1), second.minutes)
    }

    @Test
    fun `time on our own block screen is credited to no app`() {
        // Issue #284: the stream records A, then our block screen (100 s later), then B (100 s after
        // that). A owns its own 100 s; the middle 100 s is the child reading the block screen and
        // belongs to nobody; B owns its gap like any app. Before the fix that middle 100 s was
        // credited to the block screen's own package — and with no own event at all, which was the
        // phone's case, it stayed on A's name for the whole stay, capped at five minutes.
        val events = listOf(ev("com.a", 0L), ev(own, 100_000L), ev("com.b", 200_000L))
        val perApp = computePerAppMinutes(events, windowEnd = 260_000L, ownPackage = own)
        assertEquals(mapOf("com.a" to 1, "com.b" to 1), perApp.minutes)
        assertEquals(mapOf("com.a" to 40_000L), perApp.remainderMs)
        assertFalse("the agent's own window is not the child's use", perApp.minutes.containsKey(own))
        assertFalse(perApp.remainderMs.containsKey(own))
        // The own event ends A's gap but mentions no counted app: the set is per package, so only
        // A and B are suppressed in the backfill.
        assertEquals(setOf("com.a", "com.b"), perApp.eventPackages)
    }

    @Test
    fun `the gap after our own window is credited to no app`() {
        // The measured shape: the blocked app opens, the block screen comes up 1 s later, and the
        // child stays there. Nothing may accrue to the app while the overlay is in front.
        val events = listOf(ev("com.game", 0L), ev(own, 1_000L))
        val perApp = computePerAppMinutes(events, windowEnd = 10 * 60_000L, ownPackage = own)
        assertTrue(perApp.minutes.isEmpty())
        assertEquals(mapOf("com.game" to 1_000L), perApp.remainderMs)
    }

    @Test
    fun `our own package is never reported, not even from the carry`() {
        // A remainder saved before #284 could hold our own package: the block screen is foreground
        // time in UsageStats, so the old backfill counted it. It is not use either (#284).
        val window = computePerAppMinutes(
            listOf(ev("com.a", 0L)),
            windowEnd = 60_000L,
            ownPackage = own,
            carriedMs = mapOf(own to 45_000L, "com.b" to 30_000L),
        )
        assertEquals(mapOf("com.a" to 1), window.minutes)
        assertFalse(window.minutes.containsKey(own))
        assertFalse(window.remainderMs.containsKey(own))
        assertEquals(mapOf("com.b" to 30_000L), window.remainderMs)
    }

    @Test
    fun `a sub-minute event package is mentioned, a carried-only package is not`() {
        // Review R1 on #281: the backfill skips the packages the window's events mentioned even when they
        // produced no whole minute, and must still add Android's increase for a package that only carries
        // a remainder — that time was already in the previous upload's snapshot.
        val window = computePerAppMinutes(
            listOf(ev("com.a", 0L)),
            windowEnd = 40_000L,
            ownPackage = own,
            carriedMs = mapOf("com.b" to 30_000L),
        )
        assertTrue(window.minutes.isEmpty())
        assertEquals(mapOf("com.a" to 40_000L, "com.b" to 30_000L), window.remainderMs)
        assertEquals(setOf("com.a"), window.eventPackages)
    }
}
