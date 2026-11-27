package com.familyshield.agent.social

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class ConversationCapturePolicyTest {
    private val banner = "Messages and calls are end-to-end encrypted. Only people in this chat can read, listen to or share them."

    private fun node(
        text: String?,
        id: String,
        className: String = "android.widget.TextView",
        editable: Boolean = false,
        focused: Boolean = false,
        parentViewIdResourceName: String = "",
    ) = ConversationCapturePolicy.VisibleNode(text, id, className, editable, focused, parentViewIdResourceName)

    private fun resource(base: String, packageId: String): String = when (packageId) {
        "com.whatsapp" -> "com.whatsapp:id/$base"
        "com.whatsapp.w4b" -> "com.whatsapp.w4b:id/$base"
        else -> "unsupported.example:id/$base"
    }

    private fun header(name: String? = "Alex Rivera", packageId: String = "com.whatsapp") =
        node(name, resource("conversation_contact_name", packageId))
    private fun row(packageId: String = "com.whatsapp") =
        node(null, resource("conversation_text_row", packageId), "android.widget.FrameLayout")
    private fun bubble(text: String, packageId: String = "com.whatsapp") = node(
        text,
        resource("message_text", packageId),
        parentViewIdResourceName = resource("conversation_text_row", packageId),
    )

    private fun conversation(
        contact: String?,
        messages: List<String>,
        packageId: String = "com.whatsapp",
    ): List<ConversationCapturePolicy.VisibleNode> = buildList {
        add(header(contact, packageId))
        add(row(packageId))
        messages.forEach { add(bubble(it, packageId)) }
        if (packageId != "com.whatsapp") {
            add(node("com.whatsapp.w4b", "android.app.Activity", "com.whatsapp.w4b.Conversation"))
        }
    }

    @Test
    fun `short message beside encryption banner is captured without the banner or header`() {
        val conversation = ConversationCapturePolicy.parse(
            listOf(header(), row(), bubble(banner), bubble("Today"), bubble("help"), bubble("18:42")),
        )

        assertEquals("Alex Rivera", conversation?.contact)
        assertEquals(listOf("help"), conversation?.messages)
    }

    @Test
    fun `same visible screen produces no new captures`() {
        val tracker = ConversationCapturePolicy.SeenTracker()
        val texts = conversation("Alex Rivera", listOf("hello", "see you at 6"))

        assertEquals(2, tracker.newCaptures("whatsapp", texts).size)
        repeat(4) {
            assertEquals(0, tracker.newCaptures("whatsapp", texts).size)
        }
    }

    @Test
    fun `reopening old history in the same conversation adds no scans`() {
        val tracker = ConversationCapturePolicy.SeenTracker()
        val oldHistory = conversation("Alex Rivera", listOf("old incoming", "old sent"))
        tracker.newCaptures("whatsapp", oldHistory)
        tracker.newCaptures("whatsapp", conversation("Other contact", listOf("other chat")))

        assertEquals(0, tracker.newCaptures("whatsapp", oldHistory).size)
    }

    @Test
    fun `revisiting an earlier viewport does not requeue an already seen occurrence`() {
        val tracker = ConversationCapturePolicy.SeenTracker()
        tracker.newCaptures("whatsapp", conversation("Alex", listOf("one", "two", "three", "four")))
        assertEquals(listOf("five"), tracker.newCaptures("whatsapp", conversation("Alex", listOf("two", "three", "four", "five"))).map { it.text })

        assertEquals(0, tracker.newCaptures("whatsapp", conversation("Alex", listOf("three", "four"))).size)
        assertEquals(0, tracker.newCaptures("whatsapp", conversation("Alex", listOf("two", "three"))).size)
    }

    @Test
    fun `two genuinely separate messages with identical text both capture`() {
        val tracker = ConversationCapturePolicy.SeenTracker()
        val first = tracker.newCaptures("whatsapp", conversation("Alex", listOf("ok", "later", "ok")))

        val second = tracker.newCaptures("whatsapp", conversation("Alex", listOf("ok", "later", "ok", "ok")))

        assertEquals(3, first.size)
        assertEquals(listOf("ok"), second.map { it.text })
        assertNotEquals(first.last().occurrenceId, second.single().occurrenceId)
        assertTrue(!first.last().occurrenceId.contains("Alex"))
    }

    @Test
    fun `same text in two conversations is tracked independently`() {
        val tracker = ConversationCapturePolicy.SeenTracker()

        val first = tracker.newCaptures("whatsapp", conversation("Alex", listOf("same text")))
        val second = tracker.newCaptures("whatsapp", conversation("Sam", listOf("same text")))

        assertEquals(1, first.size)
        assertEquals(1, second.size)
        assertNotEquals(first.single().occurrenceId, second.single().occurrenceId)
    }

    @Test
    fun `whatsapp and whatsapp business do not share conversation state`() {
        val tracker = ConversationCapturePolicy.SeenTracker()
        val personal = conversation("Alex", listOf("same text"))
        val business = conversation("Alex", listOf("same text"), packageId = "com.whatsapp.w4b")

        assertEquals(1, tracker.newCaptures("whatsapp", personal).size)
        assertEquals(1, tracker.newCaptures("whatsapp", business, packageId = "com.whatsapp.w4b").size)
    }

    @Test
    fun `compose draft is never captured even beside a real bubble`() {
        val nodes = listOf(
            header(), row(), bubble("already sent"),
            node("unsent harmful draft", "com.whatsapp:id/entry", "android.widget.EditText", editable = true, focused = true),
        )

        val conversation = ConversationCapturePolicy.parse(nodes)

        assertEquals(listOf("already sent"), conversation?.messages)
    }

    @Test
    fun `unknown layout and partial message row fail closed`() {
        assertNull(ConversationCapturePolicy.parse(listOf(header(), bubble("not a recognised row").copy(parentViewIdResourceName = "com.whatsapp:id/other"))))
        assertNull(ConversationCapturePolicy.parse(listOf(node("navigation label", "com.whatsapp:id/menu"))))
    }

    @Test
    fun `capture count is capped to the newest bubbles per event`() {
        val messages = List(30) { "message $it" }
        val conversation = ConversationCapturePolicy.parse(conversation("Alex", messages))

        assertEquals(ConversationCapturePolicy.MAX_MESSAGES_PER_EVENT, conversation?.messages?.size)
        assertEquals("message 29", conversation?.messages?.last())
    }

    @Test
    fun `seen state is bounded per conversation and expires`() {
        var now = 1_000L
        val tracker = ConversationCapturePolicy.SeenTracker(maxConversations = 2, ttlMs = 10_000L, clock = { now })
        repeat(3) { index ->
            tracker.newCaptures("whatsapp", conversation("Contact $index", listOf("message $index")))
        }
        assertEquals(2, tracker.trackedConversations)

        now += 10_001L
        tracker.newCaptures("whatsapp", conversation("Contact 2", listOf("message 2")))
        assertEquals(1, tracker.trackedConversations)
    }

    @Test
    fun `opting out releases all conversations for that app`() {
        val tracker = ConversationCapturePolicy.SeenTracker()
        tracker.newCaptures("whatsapp", conversation("Alex", listOf("one")))
        tracker.newCaptures("discord", conversation("Sam", listOf("two")))

        tracker.forgetApp("whatsapp")

        assertEquals(1, tracker.trackedConversations)
        assertEquals(1, tracker.newCaptures("whatsapp", conversation("Alex", listOf("one"))).size)
    }

    @Test
    fun `occurrence signatures are opaque and deterministic`() {
        val first = ConversationCapturePolicy.occurrenceSignature("sensitive message text")
        val second = ConversationCapturePolicy.occurrenceSignature("sensitive message text")

        assertEquals(first, second)
        assertEquals(64, first.length)
        assertTrue(!first.contains("sensitive message text"))
    }

    @Test
    fun `conversation lines preserve document order`() {
        val conversation = ConversationCapturePolicy.parse(conversation("Alex", listOf("first", "second", "third")))

        assertEquals(listOf("first", "second", "third"), conversation?.messages)
        assertTrue(conversation?.messages?.isNotEmpty() == true)
    }
}
