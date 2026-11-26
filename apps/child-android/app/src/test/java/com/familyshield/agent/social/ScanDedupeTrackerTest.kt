package com.familyshield.agent.social

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class ScanDedupeTrackerTest {
    @Test
    fun `same occurrence from one source is deduplicated`() {
        val tracker = ScanDedupeTracker()

        assertTrue(tracker.shouldEnqueue("whatsapp", "Alex", "ok", 1_000L, "notification", "n-1"))
        assertFalse(tracker.shouldEnqueue("whatsapp", "Alex", "ok", 1_100L, "notification", "n-1"))
    }

    @Test
    fun `genuinely new occurrence of identical text is not swallowed`() {
        val tracker = ScanDedupeTracker()
        assertTrue(tracker.shouldEnqueue("whatsapp", "Alex", "ok", 1_000L, "notification", "n-1"))

        assertTrue(tracker.shouldEnqueue("whatsapp", "Alex", "ok", 2_000L, "notification", "n-2"))
    }

    @Test
    fun `screen and notification copies of one line are deduplicated across sources`() {
        val tracker = ScanDedupeTracker()
        assertTrue(tracker.shouldEnqueue("whatsapp", "Alex", "same line", 10_000L, "notification", "n-1"))

        assertFalse(tracker.shouldEnqueue("whatsapp", "Alex", "same line", 10_500L, "screen", "s-1"))
    }

    @Test
    fun `old screen history does not rescan a line already sent by notification`() {
        val tracker = ScanDedupeTracker()
        assertTrue(tracker.shouldEnqueue("whatsapp", "Alex", "old line", 1_000L, "notification", "n-1"))

        assertFalse(tracker.shouldEnqueue("whatsapp", "Alex", "old line", 61_000L, "screen", "s-1"))
    }

    @Test
    fun `identical notification lines one minute apart both scan`() {
        val tracker = ScanDedupeTracker()
        assertTrue(tracker.shouldEnqueue("whatsapp", "Alex", "repeat", 1_000L, "notification", "n-1"))

        assertTrue(tracker.shouldEnqueue("whatsapp", "Alex", "repeat", 61_000L, "notification", "n-2"))
    }

    @Test
    fun `same text outside the cross source window can be a new line`() {
        val tracker = ScanDedupeTracker()
        assertTrue(tracker.shouldEnqueue("whatsapp", "Alex", "same line", 10_000L, "notification", "n-1"))

        assertTrue(
            tracker.shouldEnqueue(
                "whatsapp",
                "Alex",
                "same line",
                10_000L + ScanDedupeTracker.CROSS_SOURCE_DEDUPE_WINDOW_MS + 1L,
                "screen",
                "s-2",
            ),
        )
    }

    @Test
    fun `expired occurrence state is pruned`() {
        val tracker = ScanDedupeTracker()

        assertTrue(tracker.shouldEnqueue("whatsapp", "Alex", "ok", 1_000L, "notification", "n-1"))
        assertTrue(
            tracker.shouldEnqueue(
                "whatsapp",
                "Alex",
                "ok",
                1_000L + ScanDedupeTracker.DEDUPE_WINDOW_MS + 1L,
                "notification",
                "n-1",
            ),
        )
    }
}
