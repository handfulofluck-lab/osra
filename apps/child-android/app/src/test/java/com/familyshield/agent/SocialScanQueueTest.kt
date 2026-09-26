package com.familyshield.agent

import com.familyshield.agent.social.SocialScanQueue
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/** Pure-JVM tests for the social scan queue dedupe hash and rate limiter (Features #2/#17). */
class SocialScanQueueTest {

    @Test
    fun `dedupeHash is stable for identical input`() {
        val a = SocialScanQueue.dedupeHash("whatsapp", "Alex", "hello there")
        val b = SocialScanQueue.dedupeHash("whatsapp", "Alex", "hello there")
        assertEquals(a, b)
        assertEquals(16, a.length)
    }

    @Test
    fun `dedupeHash differs across apps contacts and texts`() {
        val base = SocialScanQueue.dedupeHash("whatsapp", "Alex", "hello there")
        assertNotEquals(base, SocialScanQueue.dedupeHash("discord", "Alex", "hello there"))
        assertNotEquals(base, SocialScanQueue.dedupeHash("whatsapp", "Sam", "hello there"))
        assertNotEquals(base, SocialScanQueue.dedupeHash("whatsapp", "Alex", "hello there!"))
    }

    @Test
    fun `dedupeHash treats null contact as empty`() {
        assertEquals(
            SocialScanQueue.dedupeHash("whatsapp", null, "hi"),
            SocialScanQueue.dedupeHash("whatsapp", "", "hi"),
        )
    }

    @Test
    fun `rate limit allows up to max sends per window`() {
        val now = 100_000L
        val window = 60_000L
        // 29 sends in the last minute -> one more fits under the cap of 30.
        val stamps = List(29) { now - it * 1000L }
        assertTrue(SocialScanQueue.withinRateLimit(stamps, now, window, 30))
        // 30 sends -> cap reached.
        val full = List(30) { now - it * 1000L }
        assertFalse(SocialScanQueue.withinRateLimit(full, now, window, 30))
    }

    @Test
    fun `rate limit ignores stale timestamps`() {
        val now = 100_000L
        val stale = listOf(now - 120_000L, now - 90_000L) // outside the 60 s window
        assertTrue(SocialScanQueue.withinRateLimit(stale, now, 60_000L, 2))
    }
}
