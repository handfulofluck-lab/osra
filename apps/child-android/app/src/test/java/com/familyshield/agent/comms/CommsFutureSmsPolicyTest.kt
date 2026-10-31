package com.familyshield.agent.comms

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Issue #264 (F1): a text received while the clock is set forward reached the parent only when the real
 * date caught up — up to a year — because `harvestSms` skipped the row and the watermark could not move
 * to its date. The fix imports it once and remembers it; this holds the remembering.
 */
class CommsFutureSmsPolicyTest {

    private val now = 1_792_563_200_000L
    private val aYearAhead = now + 365L * 24 * 60 * 60 * 1000

    @Test
    fun `the identity carries the date first, and never the number`() {
        assertEquals("$aYearAhead|42|abc123", CommsFutureSmsPolicy.entry(aYearAhead, 42L, "abc123"))
        val entry = CommsFutureSmsPolicy.entry(aYearAhead, 42L, CommsFutureSmsPolicy.digest("+10000000257"))
        assertFalse("a parent's preference file must not hold a contact's number", entry.contains("10000000257"))
    }

    @Test
    fun `the digest is stable and short`() {
        val first = CommsFutureSmsPolicy.digest("+10000000257")
        assertEquals(first, CommsFutureSmsPolicy.digest("+10000000257"))
        assertFalse(first == CommsFutureSmsPolicy.digest("+10000000258"))
        assertEquals(12, first.length)
        assertEquals("", CommsFutureSmsPolicy.digest(""))
    }

    @Test
    fun `an entry is dropped once the watermark has passed its date`() {
        val older = CommsFutureSmsPolicy.entry(now - 1_000L, 1L, "x")
        val newer = CommsFutureSmsPolicy.entry(aYearAhead, 2L, "y")

        val pruned = CommsFutureSmsPolicy.prune(setOf(older, newer), now)
        assertFalse("normal collection covers a row the watermark has reached", older in pruned)
        assertTrue("a row still in the future stays remembered", newer in pruned)
    }

    @Test
    fun `the set is bounded, keeping the newest dates`() {
        val last = CommsFutureSmsPolicy.MAX_TRACKED + 5
        var seen: Set<String> = emptySet()
        for (i in 1..last) {
            seen = CommsFutureSmsPolicy.remember(
                seen,
                CommsFutureSmsPolicy.entry(aYearAhead + i * 1_000L, i.toLong(), "d"),
            )
        }
        assertEquals(CommsFutureSmsPolicy.MAX_TRACKED, seen.size)
        assertTrue(
            "the newest row survives the cap",
            CommsFutureSmsPolicy.entry(aYearAhead + last * 1_000L, last.toLong(), "d") in seen,
        )
        assertFalse(
            "the oldest is the one dropped",
            CommsFutureSmsPolicy.entry(aYearAhead + 1_000L, 1L, "d") in seen,
        )
    }

    @Test
    fun `a future row is imported once across three harvests, and a normal row after it still is`() {
        // The three harvests Claude asked for, simulated against the pure rules: same rows each time, the
        // same seen set carried over, a normal message arriving in the last round.
        val future = CommsFutureSmsPolicy.entry(aYearAhead, 7L, CommsFutureSmsPolicy.digest("+10000000257"))
        val normal = "$1999999999999|8|z" // dated after `now`, inside the skew
        var seen: Set<String> = emptySet()
        val floor = 6L // the row above was inserted after collection opened

        fun harvest(rows: List<Pair<String, Boolean>>, now: Long): Int {
            var imported = 0
            for ((entry, isFuture) in rows) {
                val tracked = CommsFutureSmsPolicy.isTracked(seen, entry)
                val rowId = entry.split('|')[1].toLong()
                if (isFuture) {
                    if (tracked) continue
                    if (CommsFutureSmsPolicy.shouldImportFuture(rowId, floor)) imported += 1
                    seen = CommsFutureSmsPolicy.remember(seen, entry)
                    continue
                }
                if (tracked) continue // #264 review D1: the set is checked here too
                imported += 1
            }
            return imported
        }

        assertEquals("the future row reaches the parent on the first harvest", 1, harvest(listOf(future to true), now))
        assertEquals("and is not uploaded again five minutes later", 0, harvest(listOf(future to true), now))
        assertEquals(
            "a normal message after it is still imported",
            1,
            harvest(listOf(future to true, normal to false), now),
        )
        assertEquals(
            "and when the real date finally arrives it is not imported a second time (#264 review D1)",
            0,
            harvest(listOf(future to false), aYearAhead),
        )
        assertTrue("it stays remembered until the watermark passes it", CommsFutureSmsPolicy.isTracked(seen, future))
    }

    @Test
    fun `a future-dated row that existed before collection opened is never imported`() {
        // #264 review D2: a withdrawal round trip or a fresh install can leave a text dated ahead that
        // is older than the window. It is remembered without importing, so the tracked check keeps it
        // out even when its date arrives.
        val premWindow = CommsFutureSmsPolicy.entry(aYearAhead, 5L, "old")
        val floor = 5L // the newest id when the window opened -- this row is exactly at it
        var seen: Set<String> = emptySet()
        var imported = 0

        fun harvest(isFuture: Boolean) {
            val tracked = CommsFutureSmsPolicy.isTracked(seen, premWindow)
            if (isFuture) {
                if (tracked) return
                if (CommsFutureSmsPolicy.shouldImportFuture(5L, floor)) imported += 1
                seen = CommsFutureSmsPolicy.remember(seen, premWindow)
                return
            }
            if (tracked) return
            imported += 1
        }

        harvest(isFuture = true)
        harvest(isFuture = false)
        assertEquals("a text from before the window never reaches the parent", 0, imported)
        assertTrue(CommsFutureSmsPolicy.isTracked(seen, premWindow))
    }

    @Test
    fun `the id floor admits above it, refuses at it, and treats unknown as no floor`() {
        assertTrue("a row that arrived after the window opened", CommsFutureSmsPolicy.shouldImportFuture(11L, 10L))
        assertFalse("a row at the boundary existed when the window opened", CommsFutureSmsPolicy.shouldImportFuture(10L, 10L))
        assertFalse("and one below it certainly did", CommsFutureSmsPolicy.shouldImportFuture(9L, 10L))
        assertTrue(
            "an unread floor is resolved by the caller, not treated as 'import everything'",
            CommsFutureSmsPolicy.shouldImportFuture(1L, -1L),
        )
    }

    @Test
    fun `a row read under the forward clock is remembered when the clock comes back (#513)`() {
        // The year-ahead text that reached the parent twice. Under the forward clock it is not future, so it
        // is imported and moves the watermark to its date; the clock then goes back, and the next harvest
        // would see the same row as a brand-new future one. Everything with now < DATE <= stored was read
        // once already, and remembering it is what keeps the second import out.
        val stored = aYearAhead
        val remembered = CommsFutureSmsPolicy.seenOnClockBack(
            rows = listOf(
                CommsFutureSmsPolicy.ClockBackRow(aYearAhead - 1_000L, 42L, "abc123"), // read under the forward clock
                CommsFutureSmsPolicy.ClockBackRow(now + 120_000L, 43L, "def456"),      // inside the skew
            ),
            now = now,
            stored = stored,
        )
        assertTrue(
            "the year-ahead text is tracked under the identity the harvest uses",
            CommsFutureSmsPolicy.entry(aYearAhead - 1_000L, 42L, "abc123") in remembered,
        )
        assertTrue(
            "and a row inside the skew was read too",
            CommsFutureSmsPolicy.entry(now + 120_000L, 43L, "def456") in remembered,
        )
        assertEquals(2, remembered.size)
    }

    @Test
    fun `rows the forward clock never read are not remembered, so they still arrive (#513)`() {
        // A row dated after the old watermark was never read: remembering it would drop it forever, which
        // trades one duplicate for one lost message. A row at or before now is normal collection.
        val remembered = CommsFutureSmsPolicy.seenOnClockBack(
            rows = listOf(
                CommsFutureSmsPolicy.ClockBackRow(aYearAhead + 1_000L, 50L, "gg"), // beyond the ceiling
                CommsFutureSmsPolicy.ClockBackRow(now - 1_000L, 51L, "hh"),       // behind now
                CommsFutureSmsPolicy.ClockBackRow(now, 52L, "ii"),                // exactly now
            ),
            now = now,
            stored = aYearAhead,
        )
        assertTrue("nothing here was read under the forward clock", remembered.isEmpty())
    }

    @Test
    fun `a remembered row is the one the harvest already skips (#513)`() {
        // The policy's two halves have to agree on the identity, or the clock-back branch writes entries the
        // later harvest never matches — the fix would be silent.
        val row = CommsFutureSmsPolicy.ClockBackRow(aYearAhead - 1_000L, 42L, "abc123")
        val remembered = CommsFutureSmsPolicy.seenOnClockBack(listOf(row), now, aYearAhead)
        assertTrue(
            "the entry built by the clock-back branch is the one isTracked looks for",
            CommsFutureSmsPolicy.isTracked(remembered, CommsFutureSmsPolicy.entry(row.date, row.id, row.digest)),
        )
    }
}
