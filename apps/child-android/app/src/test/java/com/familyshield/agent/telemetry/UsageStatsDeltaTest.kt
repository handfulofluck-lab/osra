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
}
