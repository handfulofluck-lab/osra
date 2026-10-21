package com.familyshield.agent.telemetry

import org.junit.Assert.assertEquals
import org.junit.Test

/**
 * Issue #267: the upload is a delta and the server adds each one to the day, so the UsageStats backfill
 * must send an increase rather than a whole-day total. These are the three cases from the issue, plus the
 * rollover that would otherwise go negative.
 */
class UsageStatsDeltaTest {

    @Test
    fun `an app absent from every window adds its increase once, not once per upload`() {
        // Morning: YouTube 60. Three later uploads mention only WhatsApp, so YouTube comes from the
        // backfill each time. Before this fix its 60 minutes were added on every one of them.
        var lastSeen: Int? = null
        var added = 0

        repeat(3) {
            added += UsageStatsDelta.deltaMinutes(60, lastSeen)
            lastSeen = 60 // recorded even though the app was not in this window's events
        }

        assertEquals("60 minutes once, not 180", 60, added)
    }

    @Test
    fun `a window without the app adds only what Android saw after the last snapshot`() {
        // First upload: nothing seen yet, so the whole 60 is new.
        assertEquals(60, UsageStatsDelta.deltaMinutes(60, null))
        // It grows to 75 while the app is not in the event stream: only 15 is new.
        assertEquals(15, UsageStatsDelta.deltaMinutes(75, 60))
        // No growth: nothing to add.
        assertEquals(0, UsageStatsDelta.deltaMinutes(75, 75))
        assertEquals(0, UsageStatsDelta.deltaMinutes(60, 60))
    }

    @Test
    fun `a total below the snapshot is a new day, not a negative minute`() {
        // Midnight rollover (or a stats reset): subtracting would take minutes off the parent's day.
        assertEquals(5, UsageStatsDelta.deltaMinutes(5, 120))
        assertEquals(0, UsageStatsDelta.deltaMinutes(0, 120))
    }

    @Test
    fun `a re-grant baseline excludes what Android has already counted`() {
        val totals = mapOf("youtube" to 90, "whatsapp" to 20)
        val baseline = UsageStatsDelta.baseline(totals)

        assertEquals(totals, baseline)
        // The next upload adds nothing for those minutes, which is the point of the baseline.
        assertEquals(0, UsageStatsDelta.deltaMinutes(90, baseline["youtube"]))
        // And a later increase is still counted.
        assertEquals(10, UsageStatsDelta.deltaMinutes(100, baseline["youtube"]))
    }

    // ── #272 review: the bucket, and the first upload ────────────────────────────────────────────────

    @Test
    fun `the same bucket adds only the increase`() {
        // Android rolls INTERVAL_DAILY at a time it picks, so "same bucket" is the only safe identity.
        assertEquals(15, UsageStatsDelta.deltaForUpload(75, 60, rollover = false, hasSnapshot = true))
        assertEquals(0, UsageStatsDelta.deltaForUpload(60, 60, rollover = false, hasSnapshot = true))
    }

    @Test
    fun `a new bucket adds its whole totals once`() {
        // The bucket began after the last upload, so everything in it is new. Yesterday's 60 minutes were
        // already sent as increments while that bucket was current.
        assertEquals(12, UsageStatsDelta.deltaForUpload(12, 60, rollover = true, hasSnapshot = true))
    }

    @Test
    fun `with no snapshot nothing is added, and the baseline is recorded instead`() {
        // A fresh pairing: this total reaches back before OSRA was installed, and #229 says collection
        // starts at the grant. The event stream covers the window from the grant to this upload.
        assertEquals(0, UsageStatsDelta.deltaForUpload(998, null, rollover = false, hasSnapshot = false))
    }

    @Test
    fun `a rollover inside one bucket view never subtracts`() {
        assertEquals(5, UsageStatsDelta.deltaForUpload(5, 120, rollover = false, hasSnapshot = true))
        assertEquals(0, UsageStatsDelta.deltaForUpload(0, 120, rollover = false, hasSnapshot = true))
    }

    // ── #272 review D3: a moved bucket key is not a rollover ─────────────────────────────────────────

    private val bucketA = 1_700_000_000_000L

    @Test
    fun `a clock shift that moves the key but not the counters adds only the increases`() {
        val lastSeen = mapOf("youtube" to 60, "whatsapp" to 20)
        val totals = mapOf("youtube" to 63, "whatsapp" to 20) // +3 minutes, key moved +3 min
        val rollover = UsageStatsDelta.isRollover(bucketA, bucketA + 180_000L, lastSeen, totals)

        assertEquals(false, rollover)
        assertEquals(3, UsageStatsDelta.deltaForUpload(63, 60, rollover, hasSnapshot = true))
        assertEquals(0, UsageStatsDelta.deltaForUpload(20, 20, rollover, hasSnapshot = true))
    }

    @Test
    fun `a clock set back with identical totals adds nothing`() {
        val lastSeen = mapOf("youtube" to 60)
        val totals = mapOf("youtube" to 60)
        val rollover = UsageStatsDelta.isRollover(bucketA, bucketA - 3_600_000L, lastSeen, totals)

        assertEquals(false, rollover)
        assertEquals(0, UsageStatsDelta.deltaForUpload(60, 60, rollover, hasSnapshot = true))
    }

    @Test
    fun `a real rollover is a counter that went down`() {
        val lastSeen = mapOf("youtube" to 120)
        val totals = mapOf("youtube" to 4)
        val rollover = UsageStatsDelta.isRollover(bucketA, bucketA + 86_400_000L, lastSeen, totals)

        assertEquals(true, rollover)
        assertEquals(4, UsageStatsDelta.deltaForUpload(4, 120, rollover, hasSnapshot = true))
    }

    @Test
    fun `a package that had minutes and vanished is a rollover`() {
        val lastSeen = mapOf("youtube" to 120, "whatsapp" to 5)
        val totals = mapOf("whatsapp" to 6)
        assertEquals(true, UsageStatsDelta.isRollover(bucketA, bucketA + 1L, lastSeen, totals))
    }

    @Test
    fun `every app above its snapshot falls back to increments, the documented under-count`() {
        val lastSeen = mapOf("youtube" to 120)
        val totals = mapOf("youtube" to 130)
        val rollover = UsageStatsDelta.isRollover(bucketA, bucketA + 1L, lastSeen, totals)

        assertEquals(false, rollover)
        assertEquals(10, UsageStatsDelta.deltaForUpload(130, 120, rollover, hasSnapshot = true))
    }

    @Test
    fun `no snapshot is never a rollover`() {
        assertEquals(false, UsageStatsDelta.isRollover(null, bucketA, emptyMap(), mapOf("youtube" to 5)))
    }
}
