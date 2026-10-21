package com.familyshield.agent

import com.familyshield.agent.data.AgentSettings
import com.familyshield.agent.data.RuleEngine
import com.familyshield.agent.data.RuleRepository
import com.familyshield.agent.data.UsageCounters
import com.familyshield.agent.network.dto.AppRuleDto
import com.familyshield.agent.network.dto.RuleSetDto
import com.familyshield.agent.network.dto.ScreenTimeRuleDto
import java.time.LocalDate
import java.time.ZoneOffset
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/** Pure-JVM tests for the daily usage counters (extracted from RuleRepository). */
class UsageCountersTest {

    private val day1: LocalDate = LocalDate.of(2026, 9, 14)
    private val day2: LocalDate = day1.plusDays(1)

    @Test
    fun `a stay on our own block screen is credited to no app`() {
        // Issue #284: measured on the Flip4 — 103 s on a bedtime block screen charged My Files 103 s,
        // and a 1-minute limit then fired 0.9 s after the app was opened.
        val c = UsageCounters()
        c.onForegroundEvent("com.game", 0L, day1)
        c.onForegroundEnded(3 * 60_000L, day1) // the block screen comes up
        // Ten minutes pass on the block screen, then the child presses Home.
        c.onForegroundEvent("com.launcher", 13 * 60_000L, day1)
        assertEquals(mapOf("com.game" to 3), c.snapshot(13 * 60_000L, day1))
        // Nothing is in progress either: the ended interval must not be credited a second time.
        assertEquals(mapOf("com.game" to 180_000L), c.snapshotMs(13 * 60_000L, day1))
    }

    @Test
    fun `ending a foreground interval with nothing open adds nothing`() {
        val c = UsageCounters()
        c.onForegroundEnded(3 * 60_000L, day1)
        c.onForegroundEnded(5 * 60_000L, day1) // repeated events from the same block screen
        assertTrue(c.snapshot(10 * 60_000L, day1).isEmpty())
        // And the next real event is credited from its own mark, not from the first one.
        c.onForegroundEvent("com.game", 20 * 60_000L, day1)
        assertEquals(mapOf("com.game" to 2), c.snapshot(22 * 60_000L, day1))
    }

    @Test
    fun `an interval ended by our own screen is capped like any other gap`() {
        // The cap is about the unseen: a block screen left up for hours must not hand the app behind it
        // more than the five minutes a screen-off gap is worth either (#284).
        val c = UsageCounters()
        c.onForegroundEvent("com.game", 0L, day1)
        c.onForegroundEnded(60 * 60_000L, day1)
        assertEquals(mapOf("com.game" to 5), c.snapshot(60 * 60_000L, day1))
    }

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
    fun `rebuildFromEvents treats our own window as an interval end, not an app`() {
        // #284 on the startup path: dropping our own events would hand the overlay's whole stay to the
        // blocked app; crediting them would charge OSRA. It ends the interval and earns nothing.
        val c = UsageCounters()
        val events = listOf(
            "com.game" to 0L,
            "com.familyshield.agent" to 2 * 60_000L,
            "com.game" to 12 * 60_000L,
        )
        c.rebuildFromEvents(events, day1, ownPackage = "com.familyshield.agent")
        val snap = c.snapshot(12 * 60_000L, day1)
        // game: 0..2 min from the first interval; the 10 min after our own window belongs to no one.
        assertEquals(mapOf("com.game" to 2), snap)
    }

    @Test
    fun `restore populates per-app minutes and respects day boundaries`() {
        val c = UsageCounters()
        c.restore(mapOf("com.game" to 2_700_000L, "com.youtube" to 1_800_000L), day1)
        assertEquals(mapOf("com.game" to 45, "com.youtube" to 30), c.snapshot(0L, day1))
        // Rolling over to next day resets the restored counters
        assertTrue(c.snapshot(0L, day2).isEmpty())
    }

    @Test
    fun `restore keeps the seconds an early event already counted`() {
        // #286: the accessibility service can deliver an event before the startup restore runs. Clearing
        // the counters there would drop the seconds it had counted; the restore merges instead.
        val c = UsageCounters()
        c.onForegroundEvent("com.a", 0L, day1)
        c.onForegroundEvent("com.b", 30_000L, day1) // com.a earns 30 s
        c.restore(mapOf("com.a" to 90_000L), day1)
        assertEquals(mapOf("com.a" to 2), c.snapshot(30_000L, day1))
    }

    @Test
    fun `status-bar cadence of 59 point 9 seconds accumulates real minutes`() {
        val c = UsageCounters()
        // The Flip4 sends an accessibility event every ~60 s, so no single gap ever reaches a minute.
        for (i in 0..9) c.onForegroundEvent("com.video", i * 59_900L, day1)
        assertEquals(mapOf("com.video" to 10), c.snapshot(600_000L, day1))
    }

    @Test
    fun `a one minute limit is reached from sub-minute foreground gaps`() {
        val c = UsageCounters()
        c.onForegroundEvent("com.game", 0L, day1)
        c.onForegroundEvent("com.game", 30_000L, day1)
        c.onForegroundEvent("com.game", 60_000L, day1)
        val used = c.snapshot(60_000L, day1)
        assertEquals(mapOf("com.game" to 1), used)
        val rules = RuleSetDto(
            screenTime = ScreenTimeRuleDto(dailyLimitMinutes = 10_080, weekendLimitMinutes = 10_080),
            appRules = listOf(AppRuleDto(packageId = "com.game", action = "time_limit", dailyLimitMinutes = 1)),
        )
        val mondayNoon = LocalDate.of(2026, 9, 14).atTime(12, 0).atZone(ZoneOffset.UTC)
        assertEquals(
            RuleRepository.Decision.TIME_LIMIT_REACHED,
            RuleEngine().evaluate(rules, "com.game", mondayNoon, used),
        )
    }

    @Test
    fun `an old minutes snapshot restores to the same minute count`() {
        val c = UsageCounters()
        // Before #276 the snapshot held whole minutes and carried no unit key.
        val ms = RuleRepository.persistedUsageMs(mapOf("com.game" to 45L, "com.youtube" to 30L), unit = null)
        c.restore(ms, day1)
        assertEquals(mapOf("com.game" to 45, "com.youtube" to 30), c.snapshot(0L, day1))
    }

    @Test
    fun `a millisecond snapshot restores unchanged`() {
        val c = UsageCounters()
        c.restore(
            RuleRepository.persistedUsageMs(mapOf("com.game" to 2_700_000L), unit = AgentSettings.USAGE_UNIT_MS),
            day1,
        )
        assertEquals(mapOf("com.game" to 45), c.snapshot(0L, day1))
    }

    @Test
    fun `the persisted millisecond snapshot keeps a sub-minute remainder across a restart`() {
        val c = UsageCounters()
        c.onForegroundEvent("com.video", 0L, day1)
        val saved = c.snapshotMs(59_900L, day1)
        assertEquals(mapOf("com.video" to 59_900L), saved)
        // After a restart the first event only sets the mark; the restored 59.9 s completes the minute.
        val restored = UsageCounters().apply { restore(saved, day1) }
        restored.onForegroundEvent("com.video", 119_800L, day1)
        restored.onForegroundEvent("com.video", 179_700L, day1)
        assertEquals(mapOf("com.video" to 1), restored.snapshot(179_700L, day1))
    }
}
