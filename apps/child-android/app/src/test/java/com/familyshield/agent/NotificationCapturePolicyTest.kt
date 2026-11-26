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
        category: String? = null,
        conversationTitle: String? = null,
        title: String? = "Mum",
        text: String? = "where are you?",
        bigText: String? = null,
        messages: List<String?> = emptyList(),
        messageSenders: List<String?> = emptyList(),
        messageTimesMs: List<Long?> = emptyList(),
        removed: Boolean = false,
        postedAtMs: Long = 1000L,
    ) = NotificationCapturePolicy.Snapshot(
        packageId = pkg, key = key, isGroupSummary = summary, groupKey = "group-1",
        category = category, conversationTitle = conversationTitle,
        title = title, text = text, bigText = bigText, messages = messages, messageSenders = messageSenders,
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
            snap(
                key = key, title = "Work group", text = null, bigText = null,
                messages = entries.map { it.text?.toString() },
                messageSenders = entries.map { it.sender?.toString() },
                messageTimesMs = entries.map { it.atMs },
            )
        }

    private fun messageBundle(text: String, atMs: Long, sender: String? = null): Bundle {
        val b = mock(Bundle::class.java)
        `when`(b.getCharSequence("text")).thenReturn(text)
        `when`(b.getCharSequence("sender")).thenReturn(sender)
        `when`(b.getLong("time")).thenReturn(atMs)
        return b
    }

    private fun message(text: String, atMs: Long, sender: String? = null): Notification.MessagingStyle.Message {
        val m = mock(Notification.MessagingStyle.Message::class.java)
        `when`(m.text).thenReturn(text)
        `when`(m.timestamp).thenReturn(atMs)
        `when`(m.sender).thenReturn(sender)
        return m
    }

    @Test
    fun `the platform's Parcelable array of bundles carries a five message burst and its redelivery adds none`() {
        // #1141 mutant: dropping Bundle senders turns every contact into the conversation title.
        val raw: Any = arrayOf(
            messageBundle("lunch at 1?", 1_000L, "Alice"),
            messageBundle("bring the keys", 2_000L, "Bob"),
            messageBundle("on my way", 3_000L, "Alice"),
            messageBundle("park outside", 4_000L, "Bob"),
            messageBundle("call me when", 5_000L, "Alice"),
        )
        val tracker = NotificationCapturePolicy.BurstTracker()
        val first = tracker.newCaptures(snapFromExtras(raw))
        assertEquals(5, first.size)
        assertEquals(listOf("lunch at 1?", "bring the keys", "on my way", "park outside", "call me when"), first.map { it.text })
        assertEquals(listOf("Alice", "Bob", "Alice", "Bob", "Alice"), first.map { it.contact })
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

    // Issue #1027 security review (osra-security#73): the tracker holds message text, so an ineligible chat must
    // never reach it, state must be releaseable, and its lifetime and size must be bounded. Every row below fails
    // if the ordering or the bound is dropped, which is the point: a comment cannot hold that.

    @Test
    fun `the gate is asked about the app key and the sender before any state exists`() {
        val asked = mutableListOf<Pair<String, String?>>()
        val tracker = NotificationCapturePolicy.BurstTracker()
        val captures = NotificationCapturePolicy.capturesFor(
            snap(title = "Work group", messages = listOf("a"), messageTimesMs = listOf(1L)),
            tracker,
        ) { appKey, contact ->
            asked += appKey to contact
            false
        }
        assertEquals(listOf("whatsapp" to "Work group"), asked)
        assertEquals(0, captures.size)
        assertEquals(0, tracker.trackedKeys)
    }

    @Test
    fun `an ineligible chat leaves the tracker empty and a later eligible one starts from scratch`() {
        val tracker = NotificationCapturePolicy.BurstTracker()
        val burst = snap(title = "Work group", messages = listOf("a", "b", "c"), messageTimesMs = listOf(1L, 2L, 3L))
        assertEquals(0, NotificationCapturePolicy.capturesFor(burst, tracker) { _, _ -> false }.size)
        assertEquals(0, tracker.trackedKeys)
        // Now the parent designates it: all three lines are new, none were remembered from the refused pass.
        assertEquals(3, NotificationCapturePolicy.capturesFor(burst, tracker) { _, _ -> true }.size)
        assertEquals(1, tracker.trackedKeys)
    }

    @Test
    fun `an eligible burst is tracked once and its redelivery adds nothing`() {
        val tracker = NotificationCapturePolicy.BurstTracker()
        val snapshot = snap(title = "Work group", messages = listOf("a", "b"), messageTimesMs = listOf(1_000L, 2_000L))
        assertEquals(2, NotificationCapturePolicy.capturesFor(snapshot, tracker) { _, _ -> true }.size)
        assertEquals(1, tracker.trackedKeys)
        assertEquals(0, NotificationCapturePolicy.capturesFor(snapshot, tracker) { _, _ -> true }.size)
    }

    @Test
    fun `a removal releases what the notification produced`() {
        val tracker = NotificationCapturePolicy.BurstTracker()
        val allowAll = { _: String, _: String? -> true }
        NotificationCapturePolicy.capturesFor(
            snap(messages = listOf("a"), messageTimesMs = listOf(1_000L)),
            tracker,
            eligible = allowAll,
        )
        assertEquals(1, tracker.trackedKeys)
        assertEquals(0, NotificationCapturePolicy.capturesFor(snap(removed = true), tracker, eligible = allowAll).size)
        assertEquals(0, tracker.trackedKeys)
    }

    @Test
    fun `state expires after its lifetime instead of outliving the dedupe window`() {
        var clock = 1_000L
        val tracker = NotificationCapturePolicy.BurstTracker(ttlMs = 10_000L, clock = { clock })
        val snapshot = snap(messages = listOf("a"), messageTimesMs = listOf(1_000L))
        assertEquals(1, tracker.newCaptures(snapshot).size)
        assertEquals(1, tracker.trackedKeys)
        clock += 10_001L
        // The next access prunes, so the same line is new again — the state was dropped, not merely ignored.
        assertEquals(1, tracker.newCaptures(snapshot).size)
        assertEquals(1, tracker.trackedKeys)
    }

    @Test
    fun `the tracker bounds how many notifications it holds and evicts the least recently touched`() {
        val tracker = NotificationCapturePolicy.BurstTracker(maxKeys = 2)
        repeat(3) { i ->
            tracker.newCaptures(
                snap(key = "k$i", messages = listOf("m$i"), messageTimesMs = listOf((i + 1).toLong() * 1_000L)),
            )
        }
        assertEquals(2, tracker.trackedKeys)
        // k0 was evicted, so its line is new again; k2 is still held and deduped.
        assertEquals(1, tracker.newCaptures(snap(key = "k0", messages = listOf("m0"), messageTimesMs = listOf(1_000L))).size)
        assertEquals(0, tracker.newCaptures(snap(key = "k2", messages = listOf("m2"), messageTimesMs = listOf(3_000L))).size)
    }

    // Issue #1035: a parent's per-app OFF must stop the scan before anything is kept, and must release what the
    // app's notifications already left behind — the Accessibility path already stops (SocialCapture.kt:34), and
    // the notification path did not.

    @Test
    fun `a per-app off scans nothing and keeps no state`() {
        val tracker = NotificationCapturePolicy.BurstTracker()
        val burst = snap(title = "Work group", messages = listOf("a", "b", "c"), messageTimesMs = listOf(1_000L, 2_000L, 3_000L))
        val captures = NotificationCapturePolicy.capturesFor(
            burst,
            tracker,
            monitoringEnabled = { false },
            eligible = { _, _ -> true },
        )
        assertEquals(0, captures.size)
        assertEquals(0, tracker.trackedKeys)
    }

    @Test
    fun `turning an app off releases what its notifications already left in the tracker`() {
        val tracker = NotificationCapturePolicy.BurstTracker()
        val burst = snap(title = "Work group", messages = listOf("a", "b"), messageTimesMs = listOf(1_000L, 2_000L))
        assertEquals(2, NotificationCapturePolicy.capturesFor(burst, tracker, monitoringEnabled = { true }) { _, _ -> true }.size)
        assertEquals(1, tracker.trackedKeys)
        // The parent turns the app off; the next notification from it must not scan, and must not keep the old text.
        assertEquals(0, NotificationCapturePolicy.capturesFor(burst, tracker, monitoringEnabled = { false }) { _, _ -> true }.size)
        assertEquals(0, tracker.trackedKeys)
    }

    @Test
    fun `an app that is on or unmentioned still scans`() {
        val on = NotificationCapturePolicy.capturesFor(
            snap(messages = listOf("a"), messageTimesMs = listOf(1_000L)),
            NotificationCapturePolicy.BurstTracker(),
            monitoringEnabled = { true },
        ) { _, _ -> true }
        assertEquals(1, on.size)
        // The absent-key default is the repository's, not this lambda's: a missing key reads as enabled.
        assertEquals(true, com.familyshield.agent.data.RuleRepository.socialMonitoringEnabled(null, "whatsapp"))
        assertEquals(true, com.familyshield.agent.data.RuleRepository.socialMonitoringEnabled(emptyMap(), "whatsapp"))
    }

    @Test
    fun `an explicit false in the rule set is the only thing that turns an app off`() {
        assertEquals(
            false,
            com.familyshield.agent.data.RuleRepository.socialMonitoringEnabled(mapOf("whatsapp" to false), "whatsapp"),
        )
        assertEquals(
            true,
            com.familyshield.agent.data.RuleRepository.socialMonitoringEnabled(mapOf("whatsapp" to true), "whatsapp"),
        )
        // Another app's flag does not leak across apps.
        assertEquals(
            true,
            com.familyshield.agent.data.RuleRepository.socialMonitoringEnabled(mapOf("instagram" to false), "whatsapp"),
        )
        // Issue #1036: the legacy "x" key still turns Twitter off, and the canonical key wins.
        assertEquals(
            false,
            com.familyshield.agent.data.RuleRepository.socialMonitoringEnabled(mapOf("x" to false), "twitter"),
        )
        assertEquals(
            true,
            com.familyshield.agent.data.RuleRepository.socialMonitoringEnabled(mapOf("twitter" to true, "x" to false), "twitter"),
        )
    }

    @Test
    fun `whatsapp presence notices are not chat messages in the supported locales`() {
        // #1140 mutant: remove the presence-title gate and every one of these produces a concern
        // whose contact is a status word and whose body is the sender's name.
        val presenceTitles = listOf(
            "online", "typing…", "recording audio…",
            "متصل الآن", "يكتب…", "يسجل صوتًا…",
            "çevrimiçi", "yazıyor…", "ses kaydediyor…",
            "mengetik…", "merekam audio…",
            "dalam talian", "sedang menaip…", "merakam audio…",
            "en ligne", "écrit…", "enregistre un audio…",
            "آن لائن", "ٹائپ کر رہا ہے…", "آڈیو ریکارڈ کر رہا ہے…",
        )
        presenceTitles.forEach { status ->
            assertEquals(
                "presence title must not be captured: $status",
                0,
                NotificationCapturePolicy.capturesFor(
                    snap(title = status, text = "username-only sender"),
                    NotificationCapturePolicy.BurstTracker(),
                ) { _, _ -> true }.size,
            )
        }
    }

    @Test
    fun `newer timestamps do not requeue text already captured for the notification key`() {
        // #1141 mutant: timestamp-only freshness returns both copies on the first post and the
        // third copy on the update. Text dedupe must apply even when the platform supplies times.
        val tracker = NotificationCapturePolicy.BurstTracker()
        val first = tracker.newCaptures(
            burst(times = listOf(1_000L, 2_000L), texts = listOf("same words", "same words")),
        )
        assertEquals(listOf("same words"), first.map { it.text })
        val repost = tracker.newCaptures(
            burst(times = listOf(1_000L, 2_000L, 3_000L), texts = listOf("same words", "same words", "same words")),
        )
        assertEquals(emptyList<String>(), repost.map { it.text })
    }

    @Test
    fun `conversation title is the contact fallback when a message has no sender`() {
        // #1140 mutant: skipping EXTRA_CONVERSATION_TITLE leaves the generic app title as contact.
        val captures = NotificationCapturePolicy.BurstTracker().newCaptures(
            snap(
                title = "WhatsApp", conversationTitle = "Family group", text = "2 messages",
                messages = listOf("first", "second"), messageTimesMs = listOf(1_000L, 2_000L),
            ),
        )
        assertEquals(listOf("Family group", "Family group"), captures.map { it.contact })
    }

    @Test
    fun `a real chat following a presence notice is captured once with its sender`() {
        val tracker = NotificationCapturePolicy.BurstTracker()
        assertEquals(
            0,
            NotificationCapturePolicy.capturesFor(
                snap(key = "presence", title = "online", text = "username-only sender"),
                tracker,
            ) { _, _ -> true }.size,
        )
        val real = NotificationCapturePolicy.capturesFor(
            snap(
                key = "chat", category = Notification.CATEGORY_MESSAGE,
                title = "WhatsApp", text = "new messages", messages = listOf("real words"),
                messageSenders = listOf("username-only sender"), messageTimesMs = listOf(1_000L),
            ),
            tracker,
        ) { _, _ -> true }
        assertEquals(1, real.size)
        assertEquals("username-only sender", real.single().contact)
        assertEquals("real words", real.single().text)
    }

    @Test
    fun `a non message category is not captured even when its text looks like a chat`() {
        // #1140 mutant: removing the category guard lets a status notification with a person's
        // name in EXTRA_TEXT become a concern even when its title is not a known presence word.
        val captures = NotificationCapturePolicy.capturesFor(
            snap(category = Notification.CATEGORY_STATUS, title = "account name", text = "real-looking words"),
            NotificationCapturePolicy.BurstTracker(),
        ) { _, _ -> true }
        assertEquals(0, captures.size)
    }

    @Test
    fun `two senders saying the same line both arrive and a repeated snapshot adds nothing`() {
        // #1150 review mutant: text-only identity drops Bob, while removing all replay suppression
        // returns the same two captures again on the second delivery.
        val tracker = NotificationCapturePolicy.BurstTracker()
        val snapshot = snap(
            title = "Family group",
            messages = listOf("same words", "same words"),
            messageSenders = listOf("Alice", "Bob"),
            messageTimesMs = listOf(1_000L, 1_000L),
        )
        val first = tracker.newCaptures(snapshot)
        assertEquals(listOf("Alice", "Bob"), first.map { it.contact })
        assertEquals(listOf("same words", "same words"), first.map { it.text })
        assertEquals(emptyList<String>(), tracker.newCaptures(snapshot).map { it.text })
    }

    @Test
    fun `a second sender in a later snapshot at the same timestamp is not discarded`() {
        // Codex #1150 re-review mutant: atMs > lastAt discards Bob before sender+text identity
        // can prove that this is a different person, not a replay of Alice.
        val tracker = NotificationCapturePolicy.BurstTracker()
        val alice = snap(messages = listOf("same words"), messageSenders = listOf("Alice"), messageTimesMs = listOf(1_000L))
        assertEquals(listOf("Alice"), tracker.newCaptures(alice).map { it.contact })
        val both = snap(messages = listOf("same words", "same words"), messageSenders = listOf("Alice", "Bob"), messageTimesMs = listOf(1_000L, 1_000L))
        assertEquals(listOf("Bob"), tracker.newCaptures(both).map { it.contact })
        assertEquals(emptyList<String>(), tracker.newCaptures(both).map { it.text })
    }

    @Test
    fun `the category rejection is limited to whatsapp and leaves other monitored apps unchanged`() {
        // #1150 review mutant: applying the new non-message category rule before the app check
        // drops this otherwise valid Discord conversation.
        val discord = NotificationCapturePolicy.capturesFor(
            snap(pkg = "com.discord", category = Notification.CATEGORY_STATUS, title = "Alice", text = "real-looking words"),
            NotificationCapturePolicy.BurstTracker(),
        ) { _, _ -> true }
        assertEquals(1, discord.size)
        assertEquals("discord", discord.single().appKey)
        val whatsapp = NotificationCapturePolicy.capturesFor(
            snap(category = Notification.CATEGORY_STATUS, title = "account name", text = "real-looking words"),
            NotificationCapturePolicy.BurstTracker(),
        ) { _, _ -> true }
        assertEquals(0, whatsapp.size)
    }
}