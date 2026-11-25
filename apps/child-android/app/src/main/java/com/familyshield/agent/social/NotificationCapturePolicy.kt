package com.familyshield.agent.social

import android.app.Notification
import android.os.Bundle

/**
 * Plan 2.6, second half — the decisions a notification capture has to make, as a pure function.
 *
 * Android delivers the same notification over and over (every update), plus a group summary that
 * repeats its children, plus "3 new messages" placeholders, plus removals when the user swipes it
 * away or the sender deletes it. Scanning all of that would send the parent duplicate and empty
 * rows, so the judgement lives here where it can be tested case by case, and
 * [com.familyshield.agent.services.NotificationCaptureService] is the thin adapter that feeds it.
 *
 * [Snapshot] is the subset of `StatusBarNotification` this needs, as primitives: the unit suite has
 * no Robolectric, and a test that builds a snapshot is exactly as honest as one that builds the
 * platform object — the only unverified line is the field mapping in the adapter, which
 * `assembleDebug` and the hardware row cover.
 */
object NotificationCapturePolicy {

    /** The fields of a posted/removed notification that decide whether it is worth a scan. */
    data class Snapshot(
        val packageId: String,
        /** `StatusBarNotification.key` — stable for the same notification across updates. */
        val key: String,
        val isGroupSummary: Boolean = false,
        val groupKey: String? = null,
        val category: String? = null,
        val channelId: String? = null,
        val conversationTitle: String? = null,
        val title: String? = null,
        val text: String? = null,
        val bigText: String? = null,
        /** `MessagingStyle` lines, oldest first, when the app used that style (WhatsApp does). */
        val messages: List<String?> = emptyList(),
        /** Sender name for each [messages] entry, when MessagingStyle supplies one. */
        val messageSenders: List<String?> = emptyList(),
        /**
         * The timestamp of each entry in [messages], same order and length when the platform supplies it.
         * Issue #1027: a burst updates one notification, so the only way to tell "already scanned" from
         * "new line" is the message's own time; an empty list means the entries carry none.
         */
        val messageTimesMs: List<Long?> = emptyList(),
        /** True when this snapshot came from `onNotificationRemoved`. */
        val isRemoved: Boolean = false,
        val postedAtMs: Long = 0L,
    )

    /** One thing worth scanning: the app key the backend knows, the sender, and the newest line. */
    data class Capture(val appKey: String, val contact: String?, val text: String, val key: String, val postedAtMs: Long)

    /** One `EXTRA_MESSAGES` entry as the adapter hands it over: line, time and sender when supplied. */
    data class Entry(val text: CharSequence?, val atMs: Long?, val sender: CharSequence? = null)

    private val whatsAppOnlineTitles = setOf("online", "متصل الآن", "çevrimiçi", "dalam talian", "en ligne", "آن لائن")
    private val whatsAppActivityPrefixes = listOf(
        "typing", "recording audio",
        "يكتب", "يسجل صوت", "يسجل مقطع",
        "yazıyor", "ses kaydediyor", "ses kaydı",
        "mengetik", "merekam audio",
        "sedang menaip", "merakam audio",
        "écrit", "enregistre un audio", "enregistrement audio",
        "ٹائپ کر رہا ہے", "ٹائپنگ", "آڈیو ریکارڈ کر رہا ہے",
    )

    private fun isNonMessage(snapshot: Snapshot): Boolean {
        if (snapshot.category != null && snapshot.category != Notification.CATEGORY_MESSAGE) return true
        if (MonitoredApps.appKeyFor(snapshot.packageId) != "whatsapp") return false
        val title = snapshot.title?.trim()?.lowercase(java.util.Locale.ROOT) ?: return false
        return title in whatsAppOnlineTitles || whatsAppActivityPrefixes.any(title::startsWith)
    }

    /**
     * Issue #1027, review finding (Codex, on #1032): the platform fills `EXTRA_MESSAGES` with
     * `Notification.MessagingStyle.Message.getMessagesFromBundleArray(...)` — a `Parcelable[]` of `Bundle`s,
     * the line under `"text"` and its time under `"time"` — while `NotificationCompat` callers put an
     * `ArrayList<Bundle>` and pre-MessagingStyle senders put plain `CharSequence`s. Every one of those shapes
     * arrives here. A shape nobody handles does not fail loudly: the caller falls back to the single-line
     * `bigText`, which is the exact bug this issue fixes, so the shapes are enumerated rather than guessed.
     */
    fun entriesOf(raw: Any?): List<Entry> = when (raw) {
        // Parcelable[] from the platform, and ArrayList from NotificationCompat: same items, two containers.
        is Array<*> -> raw.mapNotNull(::entryOf)
        is List<*> -> raw.mapNotNull(::entryOf)
        else -> emptyList()
    }

    private fun entryOf(item: Any?): Entry? = when (item) {
        null -> null
        is Notification.MessagingStyle.Message -> Entry(
            item.text,
            item.timestamp.takeIf { it > 0L },
            if (android.os.Build.VERSION.SDK_INT >= 28) item.senderPerson?.name ?: item.sender else item.sender,
        )
        is Bundle -> Entry(
            item.getCharSequence(KEY_TEXT),
            item.getLong(KEY_TIME).takeIf { it > 0L },
            item.getCharSequence(KEY_SENDER) ?: senderPersonName(item),
        )
        is CharSequence -> Entry(item, null)
        else -> null
    }

    private fun senderPersonName(bundle: Bundle): CharSequence? =
        if (android.os.Build.VERSION.SDK_INT >= 28) {
            bundle.getParcelable<android.app.Person>(KEY_SENDER_PERSON)?.name
        } else {
            null
        }

    /** The keys `Notification.MessagingStyle.Message.getBundle()` writes; not part of the public SDK. */
    private const val KEY_TEXT = "text"
    private const val KEY_TIME = "time"
    private const val KEY_SENDER = "sender"
    private const val KEY_SENDER_PERSON = "sender_person"

    /**
     * Returns the capture to enqueue, or null when the notification carries nothing to scan.
     *
     * The order of the checks is the point: a cheap identity check first (is the app monitored at
     * all), then the structural ones (removal, group summary), then the text extraction, so a
     * "3 new messages" summary never reaches the queue even if its wording changes.
     */
    fun decide(snapshot: Snapshot): Capture? {
        val appKey = MonitoredApps.appKeyFor(snapshot.packageId) ?: return null
        if (snapshot.isRemoved) return null
        // A group summary repeats its children's text — enqueuing it too is how a parent gets two
        // alerts for one message, which is the failure mode this whole class exists to prevent.
        if (snapshot.isGroupSummary) return null
        if (isNonMessage(snapshot)) return null
        val (fallbackContact, body) = ScanQueuePolicy.fromNotification(
            snapshot.title,
            snapshot.text,
            snapshot.bigText,
            snapshot.messages,
        ) ?: return null
        val contact = snapshot.messageSenders.asReversed().firstNotNullOfOrNull { ScanQueuePolicy.contactOf(it) }
            ?: ScanQueuePolicy.contactOf(snapshot.conversationTitle)
            ?: fallbackContact
        return Capture(appKey = appKey, contact = contact, text = body, key = snapshot.key, postedAtMs = snapshot.postedAtMs)
    }

    /**
     * Issue #1027 security review (`osra-security#73`): **scope is decided before any state is kept.**
     *
     * [BurstTracker] remembers message text, so it must never see a notification the parent has not
     * designated: the eligibility check runs on the app key and each line's resolved sender before the
     * tracker can remember that line. A removal releases the key instead of returning early, so a chat
     * the parent de-scopes does not leave its text behind for the life of the service.
     *
     * Pure, with the gate injected, so the ordering itself is a testable claim rather than a line in the
     * service that a reviewer has to trust.
     */
    fun capturesFor(
        snapshot: Snapshot,
        tracker: BurstTracker,
        monitoringEnabled: (appKey: String) -> Boolean = { true },
        eligible: (appKey: String, contact: String?) -> Boolean,
    ): List<Capture> {
        val appKey = MonitoredApps.appKeyFor(snapshot.packageId) ?: return emptyList()
        if (snapshot.isRemoved) {
            tracker.forget(snapshot.key)
            return emptyList()
        }
        if (snapshot.isGroupSummary) return emptyList()
        if (isNonMessage(snapshot)) return emptyList()
        // Issue #1035: a parent's per-app OFF stops the scan *and* releases what this notification left behind,
        // so turning an app off cannot leave its text in memory until the tracker's lifetime runs out.
        if (!monitoringEnabled(appKey)) {
            tracker.forget(snapshot.key)
            return emptyList()
        }
        return tracker.newCaptures(snapshot) { contact -> eligible(appKey, contact) }
    }

    /**
     * Issue #1027: the stateful half of the capture decision — which lines of a notification have already been
     * scanned. A WhatsApp burst updates **one** notification and Android re-delivers it on every update, so the
     * service needs to answer "what is new in this notification?" rather than "what does it say now?".
     *
     * Kept separate from the pure policy so it can be tested without Android, and kept in the service instance
     * rather than in a singleton so a process death simply re-reads the current notification (at worst one line
     * is scanned twice; the queue's content-hash dedupe still drops the repeat).
     *
     * **Bounded on purpose** (`osra-security#73`): an entry holds message text, so its lifetime is capped by
     * [ttlMs], its total size by [maxKeys] keys and [maxLinesPerKey] lines, and both are enforced on every
     * call rather than only on removal — a notification the user swipes away may never produce a removal at all.
     */
    class BurstTracker(
        private val maxLinesPerKey: Int = 64,
        private val maxKeys: Int = 32,
        private val ttlMs: Long = 10 * 60 * 1000L,
        private val clock: () -> Long = System::currentTimeMillis,
    ) {

        private data class Seen(val lastAtMs: Long, val touchedAtMs: Long, val texts: ArrayDeque<String>)

        /** Insertion order is touch order: the least recently touched key is the first one. */
        private val seen = LinkedHashMap<String, Seen>()

        /** How many notifications currently hold state; the tests assert this returns to zero. */
        val trackedKeys: Int get() = seen.size

        /** Release everything this notification produced; called on removal and available to the service. */
        fun forget(key: String) {
            seen.remove(key)
        }

        /** Every eligible line of [snapshot] that has not been scanned yet, oldest first. */
        fun newCaptures(snapshot: Snapshot, eligible: (contact: String?) -> Boolean = { true }): List<Capture> {
            prune()
            val appKey = MonitoredApps.appKeyFor(snapshot.packageId) ?: return emptyList()
            if (snapshot.isRemoved) return emptyList()
            if (snapshot.isGroupSummary) return emptyList()
            if (isNonMessage(snapshot)) return emptyList()

            val lines = linesOf(snapshot).filter { eligible(it.contact) }
            if (lines.isEmpty()) return emptyList()

            val state = seen[snapshot.key]
            val candidates = when {
                lines.any { it.atMs != null } -> {
                    val lastAt = state?.lastAtMs ?: 0L
                    lines.filter { it.atMs != null && it.atMs > lastAt }
                }
                else -> lines
            }
            // Timestamps identify notification revisions, not unique messages. WhatsApp can repeat a line
            // with a newer time, so content already queued for this key is excluded on both platform paths.
            val fresh = candidates
                .filter { line -> state?.texts?.contains(line.text) != true }
                .distinctBy { it.text }
            if (fresh.isEmpty()) return emptyList()

            val lastAt = lines.mapNotNull { it.atMs }.maxOrNull() ?: state?.lastAtMs ?: 0L
            val texts = state?.texts ?: ArrayDeque()
            fresh.forEach { line ->
                if (texts.size >= maxLinesPerKey) texts.removeFirst()
                texts.addLast(line.text)
            }
            remember(snapshot.key, Seen(lastAtMs = lastAt, touchedAtMs = clock(), texts = texts))

            return fresh.map {
                Capture(
                    appKey = appKey,
                    contact = it.contact,
                    text = it.text,
                    key = snapshot.key,
                    postedAtMs = it.atMs ?: snapshot.postedAtMs,
                )
            }
        }

        private data class Line(val text: String, val atMs: Long?, val contact: String?)

        /** Drops entries older than [ttlMs]; called on every access so an idle key cannot outlive its use. */
        private fun prune() {
            val cutoff = clock() - ttlMs
            seen.entries.removeAll { it.value.touchedAtMs < cutoff }
        }

        /** Records [value] as the most recently touched key and evicts the oldest when over [maxKeys]. */
        private fun remember(key: String, value: Seen) {
            seen.remove(key)
            seen[key] = value
            while (seen.size > maxKeys) {
                val oldest = seen.keys.firstOrNull() ?: return
                seen.remove(oldest)
            }
        }

        /**
         * Message entries carry their own sender, timestamp and resolved contact. Sender wins, then the
         * conversation title, then the notification title. Per-line placeholder cleaning is unchanged.
         */
        private fun linesOf(snapshot: Snapshot): List<Line> {
            val fallbackContact = ScanQueuePolicy.contactOf(snapshot.conversationTitle)
                ?: ScanQueuePolicy.contactOf(snapshot.title)
            val fromMessages = snapshot.messages.mapIndexedNotNull { index, raw ->
                val text = ScanQueuePolicy.cleanText(raw) ?: return@mapIndexedNotNull null
                val contact = ScanQueuePolicy.contactOf(snapshot.messageSenders.getOrNull(index)) ?: fallbackContact
                Line(text, snapshot.messageTimesMs.getOrNull(index), contact)
            }
            if (fromMessages.isNotEmpty()) return fromMessages
            val fallback = ScanQueuePolicy.cleanText(snapshot.bigText) ?: ScanQueuePolicy.cleanText(snapshot.text)
            return if (fallback != null) listOf(Line(fallback, null, fallbackContact)) else emptyList()
        }
    }
}
