package com.familyshield.agent.social

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class ScanDedupeTrackerTest {
    private fun admit(
        tracker: ScanDedupeTracker,
        nowMs: Long,
        source: String,
        occurrenceId: String?,
        text: String = "ok",
    ) {
        assertTrue(tracker.canEnqueue("whatsapp", "Alex", text, nowMs, source, occurrenceId))
        tracker.record("whatsapp", "Alex", text, nowMs, source, occurrenceId)
    }

    @Test
    fun `same occurrence from one source is deduplicated`() {
        val tracker = ScanDedupeTracker()
        admit(tracker, 1_000L, "notification", "n-1")

        assertFalse(tracker.canEnqueue("whatsapp", "Alex", "ok", 1_100L, "notification", "n-1"))
    }

    @Test
    fun `genuinely new occurrence of identical text is not swallowed`() {
        val tracker = ScanDedupeTracker()
        admit(tracker, 1_000L, "notification", "n-1")

        admit(tracker, 2_000L, "notification", "n-2")
    }

    @Test
    fun `screen and notification copies of one line are deduplicated across sources`() {
        val tracker = ScanDedupeTracker()
        admit(tracker, 10_000L, "notification", "n-1", text = "same line")

        assertFalse(tracker.canEnqueue("whatsapp", "Alex", "same line", 10_500L, "screen", "s-1"))
    }

    @Test
    fun `cross source comparison normalizes whitespace`() {
        val tracker = ScanDedupeTracker()
        admit(tracker, 10_000L, "notification", "n-1", text = "same  line")

        assertFalse(tracker.canEnqueue("whatsapp", "Alex", "same\nline", 10_500L, "screen", "s-1"))
    }

    @Test
    fun `old screen history does not rescan a line already sent by notification`() {
        val tracker = ScanDedupeTracker()
        admit(tracker, 1_000L, "notification", "n-1", text = "old line")

        assertFalse(tracker.canEnqueue("whatsapp", "Alex", "old line", 61_000L, "screen", "s-1"))
    }

    @Test
    fun `identical notification lines one minute apart both scan`() {
        val tracker = ScanDedupeTracker()
        admit(tracker, 1_000L, "notification", "n-1", text = "repeat")

        admit(tracker, 61_000L, "notification", "n-2", text = "repeat")
    }

    @Test
    fun `same text outside the cross source window can be a new line`() {
        val tracker = ScanDedupeTracker()
        admit(tracker, 10_000L, "notification", "n-1", text = "same line")

        admit(
            tracker,
            10_000L + ScanDedupeTracker.CROSS_SOURCE_DEDUPE_WINDOW_MS + 1L,
            "screen",
            "s-2",
            text = "same line",
        )
    }

    @Test
    fun `failed queue admission leaves the occurrence retryable`() {
        val tracker = ScanDedupeTracker()

        assertTrue(tracker.canEnqueue("whatsapp", "Alex", "ok", 1_000L, "notification", "n-1"))
        assertTrue(tracker.canEnqueue("whatsapp", "Alex", "ok", 1_100L, "notification", "n-1"))
    }

    @Test
    fun `callers without stable occurrence ids keep the old same source cooldown`() {
        val tracker = ScanDedupeTracker()
        admit(tracker, 1_000L, "screen", null)

        assertFalse(tracker.canEnqueue("whatsapp", "Alex", "ok", 2_000L, "screen", null))
    }

    @Test
    fun `expired occurrence state is pruned`() {
        val tracker = ScanDedupeTracker()
        admit(tracker, 1_000L, "notification", "n-1")

        admit(tracker, 1_000L + ScanDedupeTracker.DEDUPE_WINDOW_MS + 1L, "notification", "n-1")
    }
}
