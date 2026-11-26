package com.familyshield.agent.enforcement

import java.time.Instant
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotEquals
import org.junit.Test

/**
 * #1128 item 3: with `siteNames` off, blocked-site attempts must group within a 10-minute quiet
 * window (`web:YYYY-MM-DDTHH:M0`, hostless) and open a fresh alert key in later 10-minute windows
 * so the parent is still notified instead of going silent until the next UTC day.
 *
 * Mutant: reverting `AlertKeys.redactedBlockedSite` to per-day `"web:$day"` makes the cross-window
 * inequality assertion fail.
 */
class BlockedSiteWindowDedupe1128Test {

    @Test
    fun `same 10-minute UTC window produces the same hostless key`() {
        val t1 = Instant.parse("2026-11-26T12:01:05Z").toEpochMilli()
        val t2 = Instant.parse("2026-11-26T12:09:59Z").toEpochMilli()
        assertEquals("web:2026-11-26T12:00", AlertKeys.redactedBlockedSite(t1))
        assertEquals(AlertKeys.redactedBlockedSite(t1), AlertKeys.redactedBlockedSite(t2))
    }

    @Test
    fun `next 10-minute UTC window produces a new hostless key so the parent gets a fresh push`() {
        val window1 = Instant.parse("2026-11-26T12:01:00Z").toEpochMilli()
        val window2 = Instant.parse("2026-11-26T12:10:00Z").toEpochMilli()
        val key1 = AlertKeys.redactedBlockedSite(window1)
        val key2 = AlertKeys.redactedBlockedSite(window2)
        assertEquals("web:2026-11-26T12:00", key1)
        assertEquals("web:2026-11-26T12:10", key2)
        assertNotEquals(key1, key2)
    }

    @Test
    fun `hostless body reports running daily count on later attempts`() {
        assertEquals("Your child tried to open a blocked site.", AlertKeys.redactedBlockedSiteBody(1))
        assertEquals("3 blocked sites today.", AlertKeys.redactedBlockedSiteBody(3))
    }
}
