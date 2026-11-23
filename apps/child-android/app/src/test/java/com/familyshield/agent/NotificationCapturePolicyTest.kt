package com.familyshield.agent.social

import android.app.Notification
import android.os.Bundle
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Test
import org.mockito.Mockito.mock
import org.mockito.Mockito.`when`

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
        messageTimesMs: List<Long?> = emptyList(),
        removed: Boolean = false,
        postedAtMs: Long = 1000L,
    ) = NotificationCapturePolicy.Snapshot(
        packageId = pkg, key = key, isGroupSummary = summary, groupKey = "group-1",
        title = title, text = text, bigText = bigText, messages = messages,
        messageTimesMs = messageTimesMs, isRemoved = removed, postedAtMs = postedAtMs,
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

    // Issue #1027: a WhatsApp burst updates ONE notification. Karim sent ~20 messages and four reached the server,
    // because the capture path scanned only the newest line. These rows pin the fix and name their mutants.

    private fun burst(times: List<Long>, texts: List<String> = times.map { "line ${it}" }) =
        snap(title = "Work group", text = texts.last(), messages = texts, messageTimesMs = times.map { it as Long? })

    @Test
    fun `a five message burst on one notification produces five scans, oldest first`() {
        // Mutant: take messages.lastOrNull() again -> this row reports one capture and goes red.
        val tracker = NotificationCapturePolicy.BurstTracker()
        val captures = tracker.newCaptures(burst(listOf(1_000, 2_000, 3_000, 4_000, 5_000)))
        assertEquals(5, captures.size)
        assertEquals(listOf("line 1000", "line 2000", "line 3000", "line 4000", "line 5000"), captures.map { it.text })
        assertEquals(listOf(1_000L, 2_000L, 3_000L, 4_000L, 5_000L), captures.map { it.postedAtMs })
        assertEquals("Work group", captures.first().contact)
    }

    @Test
    fun `re-posting the same notification adds no scans`() {
        // Mutant: drop the seen-map entirely -> the second post returns five captures and this row goes red.
        val tracker = NotificationCapturePolicy.BurstTracker()
        val snapshot = burst(listOf(1_000, 2_000))
        assertEquals(2, tracker.newCaptures(snapshot).size)
        assertEquals(0, tracker.newCaptures(snapshot).size)
    }

    @Test
    fun `only the new lines of a growing notification are scanned`() {
        val tracker = NotificationCapturePolicy.BurstTracker()
        assertEquals(2, tracker.newCaptures(burst(listOf(1_000, 2_000))).size)
        val grown = tracker.newCaptures(burst(listOf(1_000, 2_000, 3_000, 4_000)))
        assertEquals(listOf("line 3000", "line 4000"), grown.map { it.text })
    }

    @Test
    fun `without timestamps a re-post is deduped by text`() {
        // The legacy CharSequence entries carry no time; the tracker must still not scan them twice.
        val tracker = NotificationCapturePolicy.BurstTracker()
        val snapshot = snap(title = "Mum", text = "call me", messages = listOf("are you there?", "call me"))
        assertEquals(2, tracker.newCaptures(snapshot).size)
        assertEquals(0, tracker.newCaptures(snapshot).size)
    }

    @Test
    fun `a burst whose newest line is a placeholder still scans the real messages`() {
        // The old path read the newest line; when WhatsApp's newest line is "3 new messages" the real ones were
        // hidden behind it. Per-line cleaning is what makes this case pass.
        val tracker = NotificationCapturePolicy.BurstTracker()
        val captures = tracker.newCaptures(
            snap(
                title = "Work group",
                text = "3 new messages",
                messages = listOf("lunch at 1?", "bring the keys", "3 new messages"),
                messageTimesMs = listOf(1_000L, 2_000L, 3_000L),
            ),
        )
        assertEquals(listOf("lunch at 1?", "bring the keys"), captures.map { it.text })
    }

    // Issue #1027 review (Codex, #1032): the policy rows above inject lines that are already decoded, so they
    // cannot show that the device adapter produces any. The platform fills EXTRA_MESSAGES with a Parcelable[]
    // of Bundle (text under "text", time under "time"); NotificationCompat fills an ArrayList of the same
    // Bundle; older senders put plain CharSequence in. These rows come through the same decoder the service
    // calls, so a container shape nobody handles fails here instead of on the handset.

    /** The service's own snapshotOf, minus the Android StatusBarNotification it cannot build on the JVM. */
    private fun snapFromExtras(raw: Any?, key: String = "0|com.whatsapp|1|null|10123") =
        NotificationCapturePolicy.entriesOf(raw).let { entries ->
            snap(key = key, title = "Work group", text = null, bigText = null, messages = entries.map { it.text?.toString() }, messageTimesMs = entries.map { it.atMs })
        }

    private fun messageBundle(text: String, atMs: Long): Bundle {
        val b = mock(Bundle::class.java)
        `when`(b.getCharSequence("text")).thenReturn(text)
        `when`(b.getLong("time")).thenReturn(atMs)
        return b
    }

    private fun message(text: String, atMs: Long): Notification.MessagingStyle.Message {
        val m = mock(Notification.MessagingStyle.Message::class.java)
        `when`(m.text).thenReturn(text)
        `when`(m.timestamp).thenReturn(atMs)
        return m
    }

    @Test
    fun `the platform's Parcelable array of bundles carries a five message burst and its redelivery adds none`() {
        // The documented platform shape, and the one the old adapter dropped on the floor: every line lost,
        // the snapshot fell back to bigText, and a burst scanned once instead of five times.
        val raw: Any = arrayOf(
            messageBundle("lunch at 1?", 1_000L),
            messageBundle("bring the keys", 2_000L),
            messageBundle("on my way", 3_000L),
            messageBundle("park outside", 4_000L),
            messageBundle("call me when", 5_000L),
        )
        val tracker = NotificationCapturePolicy.BurstTracker()
        val first = tracker.newCaptures(snapFromExtras(raw))
        assertEquals(5, first.size)
        assertEquals(listOf("lunch at 1?", "bring the keys", "on my way", "park outside", "call me when"), first.map { it.text })
        assertEquals(listOf(1_000L, 2_000L, 3_000L, 4_000L, 5_000L), first.map { it.postedAtMs })
        assertEquals(0, tracker.newCaptures(snapFromExtras(raw)).size)
    }

    @Test
    fun `a NotificationCompat list of bundles decodes the same as the platform array`() {
        val compat = arrayListOf(messageBundle("are you there?", 1_000L), messageBundle("call me", 2_000L))
        assertEquals(listOf("are you there?", "call me"), NotificationCapturePolicy.entriesOf(compat).map { it.text?.toString() })
        assertEquals(listOf(1_000L, 2_000L), NotificationCapturePolicy.entriesOf(compat).map { it.atMs })
    }

    @Test
    fun `a list of MessagingStyle messages keeps each line and its own time`() {
        val raw = arrayListOf(message("first", 1_000L), message("second", 2_000L))
        val entries = NotificationCapturePolicy.entriesOf(raw)
        assertEquals(listOf("first", "second"), entries.map { it.text?.toString() })
        assertEquals(listOf(1_000L, 2_000L), entries.map { it.atMs })
    }

    @Test
    fun `legacy CharSequence entries decode without times and still dedupe on redelivery`() {
        val raw: Any = arrayOf<Any>("are you there?", "call me")
        val tracker = NotificationCapturePolicy.BurstTracker()
        assertEquals(2, tracker.newCaptures(snapFromExtras(raw)).size)
        assertEquals(0, tracker.newCaptures(snapFromExtras(raw)).size)
    }

    @Test
    fun `extras that are not one of the known shapes decode to nothing rather than throwing`() {
        assertEquals(emptyList<NotificationCapturePolicy.Entry>(), NotificationCapturePolicy.entriesOf(null))
        assertEquals(emptyList<NotificationCapturePolicy.Entry>(), NotificationCapturePolicy.entriesOf("not a list"))
        assertEquals(emptyList<NotificationCapturePolicy.Entry>(), NotificationCapturePolicy.entriesOf(listOf(42)))
    }
}