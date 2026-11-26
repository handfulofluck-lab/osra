package com.familyshield.agent.social

/** Visible WhatsApp conversation lines and the bounded state that tells new bubbles from redraws. */
object ConversationCapturePolicy {
    const val MAX_MESSAGES_PER_EVENT: Int = 20
    private const val MAX_TRACKED_MESSAGES: Int = 64

    data class Conversation(val contact: String?, val messages: List<String>)
    data class Capture(val appKey: String, val contact: String?, val text: String, val occurrenceId: String)

    fun parse(texts: List<String>): Conversation? {
        val cleaned = texts.map { it.trim() }.filter { it.isNotEmpty() }
        if (cleaned.isEmpty()) return null
        val contactIndex = cleaned.indexOfFirst {
            it.length in 2..SocialHeuristics.MAX_CONTACT_LENGTH && !it.contains('\n') && !isNoise(it)
        }
        val contact = contactIndex.takeIf { it >= 0 }?.let(cleaned::get)
        val messages = cleaned.filterIndexed { index, text ->
            index != contactIndex && !isNoise(text)
        }.takeLast(MAX_MESSAGES_PER_EVENT)
        return Conversation(contact, messages)
    }

    class SeenTracker(
        private val maxConversations: Int = 32,
        private val ttlMs: Long = 30 * 60 * 1000L,
        private val clock: () -> Long = System::currentTimeMillis,
    ) {
        private data class Seen(
            val texts: ArrayDeque<String>,
            var nextOccurrenceId: Long,
            val touchedAtMs: Long,
        )

        private val seen = LinkedHashMap<String, Seen>()

        val trackedConversations: Int get() = seen.size

        fun newCaptures(appKey: String, texts: List<String>): List<Capture> {
            val conversation = parse(texts) ?: return emptyList()
            return newCaptures(appKey, conversation)
        }

        fun newCaptures(appKey: String, conversation: Conversation): List<Capture> {
            prune()
            if (conversation.messages.isEmpty()) return emptyList()
            val key = conversationKey(appKey, conversation.contact)
            val previous = seen[key]
            val previousTexts = previous?.texts?.toList().orEmpty()
            val fresh = freshSuffix(previousTexts, conversation.messages)
            var nextId = previous?.nextOccurrenceId ?: 1L
            val captures = fresh.map { text ->
                Capture(appKey, conversation.contact, text, "$key\u0000${nextId++}")
            }
            val snapshot = ArrayDeque<String>()
            snapshot.addAll(conversation.messages.takeLast(MAX_TRACKED_MESSAGES))
            remember(key, Seen(snapshot, nextId, clock()))
            return captures
        }

        fun forgetApp(appKey: String) {
            seen.keys.removeAll { it.startsWith("$appKey\u0000") }
        }

        fun clear() = seen.clear()

        private fun freshSuffix(previous: List<String>, current: List<String>): List<String> {
            val limit = minOf(previous.size, current.size)
            val overlap = (limit downTo 1).firstOrNull { size ->
                previous.takeLast(size) == current.take(size)
            } ?: 0
            return current.drop(overlap)
        }

        private fun conversationKey(appKey: String, contact: String?): String = "$appKey\u0000${contact.orEmpty()}"

        private fun prune() {
            val cutoff = clock() - ttlMs
            seen.entries.removeAll { it.value.touchedAtMs < cutoff }
        }

        private fun remember(key: String, value: Seen) {
            seen.remove(key)
            seen[key] = value
            while (seen.size > maxConversations) {
                val oldest = seen.keys.firstOrNull() ?: return
                seen.remove(oldest)
            }
        }
    }

    private fun isNoise(text: String): Boolean {
        val lower = text.lowercase()
        if (lower in NOISE) return true
        if (NOISE_PREFIXES.any(lower::startsWith)) return true
        if (lower.contains("end-to-end encrypted") || lower.contains("مشفرة") || lower.contains("مشفر")) return true
        return DATE_TIME_PATTERNS.any { it.matches(lower) }
    }

    private val NOISE = setOf(
        "online", "typing…", "typing...", "recording audio…", "recording audio...",
        "today", "yesterday", "tomorrow", "اليوم", "أمس", "امس", "غدًا", "غدا",
        "type a message", "message", "reply", "forwarded", "edited",
        "you deleted this message", "this message was deleted",
    )

    private val NOISE_PREFIXES = listOf(
        "last seen", "you deleted", "this message was deleted", "only people in this chat",
    )

    private val DATE_TIME_PATTERNS = listOf(
        Regex("^\\d{1,2}:\\d{2}(?::\\d{2})?(\\s*[ap]m)?$"),
        Regex("^\\d{1,2}[/.-]\\d{1,2}([/.-]\\d{2,4})?$"),
        Regex("^\\d{1,2}\\s+\\p{L}+\\s+\\d{4}$"),
        Regex("^\\p{L}+\\s+\\d{1,2},?\\s+\\d{4}$"),
    )
}
