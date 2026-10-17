package com.familyshield.agent.social

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Test

/**
 * Plan 2.6, second half — the notification-capture decisions, one case per thing Android actually
 * delivers: an update, a group summary, a "3 new messages" placeholder, a removal, a non-monitored
 * app, and a MessagingStyle thread. The [NotificationCapturePolicy.Snapshot] stands in for a
 * `StatusBarNotification`; the adapter's field mapping is the only line these cannot reach.
 */
class NotificationCapturePolicyTest {

    private fun snap(
        pkg: String = "com.whatsapp",
        key: String = "0|com.whatsapp|1|null|10123",
        summary: Boolean = false,
        title: String? = "Mum",
        text: String? = "where are you?",
        bigText: String? = null,
        messages: List<String?> = emptyList(),
        removed: Boolean = false,
        postedAtMs: Long = 1000L,
    ) = NotificationCapturePolicy.Snapshot(
        packageId = pkg, key = key, isGroupSummary = summary, groupKey = "group-1",
        title = title, text = text, bigText = bigText, messages = messages,
        isRemoved = removed, postedAtMs = postedAtMs,
    )

    @Test
    fun `a whatsapp message with text is captured with the sender and the text`() {
        val c = NotificationCapturePolicy.decide(snap())
        assertNotNull(c)
        assertEquals("whatsapp", c!!.appKey)
        assertEquals("Mum", c.contact)
        assertEquals("where are you?", c.text)
        assertEquals("0|com.whatsapp|1|null|10123", c.key)
        assertEquals(1000L, c.postedAtMs)
    }

    @Test
    fun `whatsapp business is the same app key`() {
        assertEquals("whatsapp", NotificationCapturePolicy.decide(snap(pkg = "com.whatsapp.w4b"))?.appKey)
    }

    @Test
    fun `an app that is not monitored is never captured`() {
        assertNull(NotificationCapturePolicy.decide(snap(pkg = "com.android.systemui", title = "USB", text = "charging")))
        assertNull(NotificationCapturePolicy.decide(snap(pkg = "com.spotify.music")))
    }

    @Test
    fun `a group summary is skipped so one message is not scanned twice`() {
        // The summary repeats the children's text; the child notification is the one to keep.
        assertNull(NotificationCapturePolicy.decide(snap(summary = true)))
    }

    @Test
    fun `a collapsed placeholder is not a message`() {
        assertNull(NotificationCapturePolicy.decide(snap(title = "WhatsApp", text = "3 new messages")))
        assertNull(NotificationCapturePolicy.decide(snap(title = "Work", text = "12 new messages from Work")))
    }

    @Test
    fun `a removed notification is not captured`() {
        assertNull(NotificationCapturePolicy.decide(snap(removed = true)))
    }

    @Test
    fun `a messaging style thread uses the newest line`() {
        val c = NotificationCapturePolicy.decide(
            snap(title = "Dad", text = "2 messages", messages = listOf("are you coming?", "call me")),
        )
        assertEquals("call me", c?.text)
        assertEquals("Dad", c?.contact)
    }

    @Test
    fun `big text beats the shortened text`() {
        val c = NotificationCapturePolicy.decide(snap(text = "Mum: are you…", bigText = "Mum: are you coming home?"))
        assertEquals("Mum: are you coming home?", c?.text)
    }

    @Test
    fun `a notification with no body is not captured`() {
        assertNull(NotificationCapturePolicy.decide(snap(text = null, bigText = null, messages = emptyList())))
        assertNull(NotificationCapturePolicy.decide(snap(text = "   ")))
    }

    @Test
    fun `an incoming call notification is not a message`() {
        assertNull(NotificationCapturePolicy.decide(snap(title = "Mum", text = "Incoming voice call")))
    }

    @Test
    fun `one messages style line with a real body still wins over the noise check`() {
        val c = NotificationCapturePolicy.decide(snap(title = "Mum", text = "new messages", messages = listOf("see you at 6")))
        assertEquals("see you at 6", c?.text)
    }
}
