package com.familyshield.agent.comms

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import java.time.Instant

/**
 * Issue #260: a comms row must reach the parent with the time it happened.
 *
 * The server's schema is `z.string().datetime()`, so the format is a contract, not a preference; and
 * the value has to round-trip exactly or the parent's timeline shifts by a timezone.
 */
class CommsEventTimestampsTest {

    // The three timestamps from issue #260's phone run: two calls eight seconds apart, and one from
    // earlier in the same hour, which all arrived stamped with the flush time instead.
    private val firstCall = 1_792_562_812_000L      // 2026-10-21T06:06:52Z
    private val secondCall = 1_792_563_280_875L     // 2026-10-21T06:14:40.875Z
    private val thirdCall = 1_792_563_288_875L      // 2026-10-21T06:14:48.875Z

    @Test
    fun `formats the epoch as ISO-8601 UTC with a Z suffix`() {
        assertEquals("1970-01-01T00:00:00Z", CommsEventTimestamps.isoUtc(0L))
        assertEquals("2026-10-21T06:06:52Z", CommsEventTimestamps.isoUtc(firstCall))
    }

    @Test
    fun `keeps milliseconds when the row has them`() {
        assertEquals("2026-10-21T06:14:40.875Z", CommsEventTimestamps.isoUtc(secondCall))
    }

    @Test
    fun `two calls eight seconds apart keep eight seconds apart`() {
        val a = Instant.parse(CommsEventTimestamps.isoUtc(secondCall)).toEpochMilli()
        val b = Instant.parse(CommsEventTimestamps.isoUtc(thirdCall)).toEpochMilli()
        assertEquals(8_000L, b - a)
        assertTrue(a != b)
    }

    @Test
    fun `round-trips to the same instant, including a clock set forward`() {
        // The last sample is a phone clock a year ahead: the client sends it unchanged and the server
        // clamps it (#260). The format must survive the trip either way.
        for (epoch in listOf(0L, firstCall, secondCall, thirdCall, 4_102_444_800_000L)) {
            val text = CommsEventTimestamps.isoUtc(epoch)
            assertTrue("not an ISO instant: $text", text.endsWith("Z"))
            assertEquals(text, epoch, Instant.parse(text).toEpochMilli())
        }
    }
}
