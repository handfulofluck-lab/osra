package com.familyshield.agent.social

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class ConversationCapturePolicyTest {
    private val banner = "Messages and calls are end-to-end encrypted. Only people in this chat can read, listen to or share them."

    @Test
    fun `short message beside encryption banner is captured without the banner or header`() {
        val conversation = ConversationCapturePolicy.parse(
            listOf("Alex Rivera", "online", banner, "Today", "help", "18:42"),
        )

        assertEquals("Alex Rivera", conversation?.contact)
        assertEquals(listOf("help"), conversation?.messages)
    }

    @Test
    fun `same visible screen produces no new captures`() {
        val tracker = ConversationCapturePolicy.SeenTracker()
        val texts = listOf("Alex Rivera", banner, "Today", "hello", "see you at 6")

        assertEquals(2, tracker.newCaptures("whatsapp", texts).size)
        repeat(4) {
            assertEquals(0, tracker.newCaptures("whatsapp", texts).size)
        }
    }

    @Test
    fun `reopening old history in the same conversation adds no scans`() {
        val tracker = ConversationCapturePolicy.SeenTracker()
        val oldHistory = listOf("Alex Rivera", banner, "Today", "old incoming", "old sent")
        tracker.newCaptures("whatsapp", oldHistory)
        tracker.newCaptures("whatsapp", listOf("Other contact", banner, "Today", "other chat"))

        assertEquals(0, tracker.newCaptures("whatsapp", oldHistory).size)
    }

    @Test
    fun `same text in two conversations is tracked independently`() {
        val tracker = ConversationCapturePolicy.SeenTracker()

        val first = tracker.newCaptures("whatsapp", listOf("Alex", banner, "Today", "same text"))
        val second = tracker.newCaptures("whatsapp", listOf("Sam", banner, "Today", "same text"))

        assertEquals(1, first.size)
        assertEquals(1, second.size)
        assertNotEquals(first.single().occurrenceId, second.single().occurrenceId)
    }

    @Test
    fun `new sent line is captured after an unchanged screen`() {
        val tracker = ConversationCapturePolicy.SeenTracker()
        tracker.newCaptures("whatsapp", listOf("Alex Rivera", banner, "Today", "incoming"))

        val captures = tracker.newCaptures("whatsapp", listOf("Alex Rivera", banner, "Today", "incoming", "sent by child"))

        assertEquals(listOf("sent by child"), captures.map { it.text })
    }

    @Test
    fun `repeated text at a new bubble position is a genuinely new capture`() {
        val tracker = ConversationCapturePolicy.SeenTracker()
        val first = tracker.newCaptures("whatsapp", listOf("Alex Rivera", banner, "Today", "ok", "later", "ok"))

        val second = tracker.newCaptures("whatsapp", listOf("Alex Rivera", banner, "Today", "ok", "later", "ok", "ok"))

        assertEquals(3, first.size)
        assertEquals(listOf("ok"), second.map { it.text })
        assertNotEquals(first.last().occurrenceId, second.single().occurrenceId)
    }

    @Test
    fun `scrolling the same bubbles does not queue them again`() {
        val tracker = ConversationCapturePolicy.SeenTracker()
        tracker.newCaptures("whatsapp", listOf("Alex", banner, "Today", "one", "two", "three", "four"))

        val captures = tracker.newCaptures("whatsapp", listOf("Alex", banner, "Today", "two", "three", "four", "five"))

        assertEquals(listOf("five"), captures.map { it.text })
        assertEquals(0, tracker.newCaptures("whatsapp", listOf("Alex", banner, "Today", "three", "four", "five")).size)
    }

    @Test
    fun `date system and input lines are not message candidates`() {
        val conversation = ConversationCapturePolicy.parse(
            listOf(
                "Alex Rivera",
                "typing…",
                "Yesterday",
                "26/11/2026",
                "You deleted this message",
                "Type a message",
                "real message",
                "7:05 PM",
            ),
        )

        assertEquals(listOf("real message"), conversation?.messages)
    }

    @Test
    fun `capture count is capped to the newest bubbles per event`() {
        val messages = List(30) { "message $it" }
        val conversation = ConversationCapturePolicy.parse(listOf("Alex", banner) + messages)

        assertEquals(ConversationCapturePolicy.MAX_MESSAGES_PER_EVENT, conversation?.messages?.size)
        assertEquals("message 29", conversation?.messages?.last())
    }

    @Test
    fun `seen state is bounded per conversation and expires`() {
        var now = 1_000L
        val tracker = ConversationCapturePolicy.SeenTracker(maxConversations = 2, ttlMs = 10_000L, clock = { now })
        repeat(3) { index ->
            tracker.newCaptures("whatsapp", listOf("Contact $index", banner, "Today", "message $index"))
        }
        assertEquals(2, tracker.trackedConversations)

        now += 10_001L
        tracker.newCaptures("whatsapp", listOf("Contact 2", banner, "Today", "message 2"))
        assertEquals(1, tracker.trackedConversations)
    }

    @Test
    fun `opting out releases all conversations for that app`() {
        val tracker = ConversationCapturePolicy.SeenTracker()
        tracker.newCaptures("whatsapp", listOf("Alex", banner, "Today", "one"))
        tracker.newCaptures("discord", listOf("Sam", "Today", "two"))

        tracker.forgetApp("whatsapp")

        assertEquals(1, tracker.trackedConversations)
        assertEquals(1, tracker.newCaptures("whatsapp", listOf("Alex", banner, "Today", "one")).size)
    }

    @Test
    fun `conversation lines preserve document order`() {
        val conversation = ConversationCapturePolicy.parse(listOf("Alex", banner, "Today", "first", "second", "third"))

        assertEquals(listOf("first", "second", "third"), conversation?.messages)
        assertTrue(conversation?.messages?.isNotEmpty() == true)
    }
}
