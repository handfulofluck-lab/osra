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
        // The three harvests Claude asked for, simulated against the pure rule: same rows each time, the
        // same seen set carried over, a normal message arriving in the last round.
        val future = CommsFutureSmsPolicy.entry(aYearAhead, 7L, CommsFutureSmsPolicy.digest("+10000000257"))
        val normal = "$1999999999999|8|z" // dated after `now`, inside the skew
        var seen: Set<String> = emptySet()

        fun harvest(rows: List<Pair<String, Boolean>>): Pair<Int, Set<String>> {
            var imported = 0
            for ((entry, isFuture) in rows) {
                if (!isFuture) {
                    imported += 1
                    continue
                }
                if (CommsFutureSmsPolicy.isTracked(seen, entry)) continue
                seen = CommsFutureSmsPolicy.remember(seen, entry)
                imported += 1
            }
            return imported to seen
        }

        val first = harvest(listOf(future to true))
        assertEquals("the future row reaches the parent on the first harvest", 1, first.first)

        val second = harvest(listOf(future to true))
        assertEquals("and is not uploaded again five minutes later", 0, second.first)

        val third = harvest(listOf(future to true, normal to false))
        assertEquals("a normal message after it is still imported", 1, third.first)
        assertTrue("the future row is still remembered", CommsFutureSmsPolicy.isTracked(third.second, future))
    }
}
