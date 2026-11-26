package com.familyshield.agent.social

/** Recognised WhatsApp conversation rows and bounded occurrence tracking for visible bubbles. */
object ConversationCapturePolicy {
    const val MAX_MESSAGES_PER_EVENT: Int = 20
    private const val MAX_OCCURRENCE_SIGNATURES: Int = 128

    data class VisibleNode(
        val text: String?,
        val viewIdResourceName: String,
        val className: String,
        val isEditable: Boolean,
        val isFocused: Boolean,
        val parentViewIdResourceName: String = "",
    )

    data class Conversation(val contact: String?, val messages: List<String>)
    data class Capture(val appKey: String, val contact: String?, val text: String, val occurrenceId: String)

    fun parse(nodes: List<VisibleNode>, packageId: String = "com.whatsapp"): Conversation? {
        if (nodes.isEmpty()) return null
        val hasHeader = nodes.any { matches(it.viewIdResourceName, "conversation_contact_name", packageId) }
        val hasMessageRow = nodes.any { matches(it.viewIdResourceName, "conversation_text_row", packageId) }
        if (!hasHeader || !hasMessageRow) return null
        val contact = nodes.firstOrNull { matches(it.viewIdResourceName, "conversation_contact_name", packageId) }
            ?.text?.trim()?.takeIf { it.isNotEmpty() }
        val messages = nodes.filter {
            matches(it.viewIdResourceName, "message_text", packageId) &&
                matches(it.parentViewIdResourceName, "conversation_text_row", packageId) &&
                !it.isEditable && !it.isFocused && !it.text.isNullOrBlank()
        }.map { it.text!!.trim() }.filter { !isNoise(it) }.takeLast(MAX_MESSAGES_PER_EVENT)
        if (messages.isEmpty()) return null
        return Conversation(contact, messages)
    }

    class SeenTracker(
        private val maxConversations: Int = 32,
        private val ttlMs: Long = 30 * 60 * 1000L,
        private val clock: () -> Long = System::currentTimeMillis,
    ) {
        private data class Seen(
            val signatures: LinkedHashSet<String>,
            var nextOccurrenceId: Long,
            val touchedAtMs: Long,
        )

        private val seen = LinkedHashMap<String, Seen>()
        val trackedConversations: Int get() = seen.size

        fun newCaptures(
            appKey: String,
            nodes: List<VisibleNode>,
            packageId: String = "com.whatsapp",
        ): List<Capture> {
            val conversation = parse(nodes, packageId) ?: return emptyList()
            return newCaptures(appKey, conversation, packageId)
        }

        fun newCaptures(
            appKey: String,
            conversation: Conversation,
            packageId: String = "com.whatsapp",
        ): List<Capture> {
            prune()
            val key = conversationKey(appKey, conversation.contact, packageId)
            val previous = seen[key]
            val signatures = previous?.signatures ?: LinkedHashSet()
            var nextId = previous?.nextOccurrenceId ?: 1L
            val captures = mutableListOf<Capture>()
            conversation.messages.forEachIndexed { index, text ->
                val previousText = conversation.messages.getOrNull(index - 1)
                val nextText = conversation.messages.getOrNull(index + 1)
                val predecessor = occurrenceSignature("P\u0000$previousText\u0000$text")
                val successor = occurrenceSignature("S\u0000$text\u0000$nextText")
                val isNew = predecessor !in signatures &&
                    (index == conversation.messages.lastIndex || successor !in signatures)
                if (isNew) {
                    captures += Capture(appKey, conversation.contact, text, "$key\u0000${nextId++}")
                }
                signatures += predecessor
                signatures += successor
            }
            while (signatures.size > MAX_OCCURRENCE_SIGNATURES) {
                signatures.remove(signatures.first())
            }
            remember(key, Seen(signatures, nextId, clock()))
            return captures
        }

        fun forgetApp(appKey: String) {
            seen.keys.removeAll { key -> key.split('\u0000').getOrNull(1) == appKey }
        }

        fun clear() = seen.clear()

        private fun conversationKey(appKey: String, contact: String?, packageId: String): String =
            "$packageId\u0000$appKey\u0000${contact.orEmpty()}"

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

    fun occurrenceSignature(raw: String): String {
        val digest = java.security.MessageDigest.getInstance("SHA-256").digest(raw.toByteArray(Charsets.UTF_8))
        return digest.joinToString("") { "%02x".format(it) }
    }

    fun isStructuralMarker(viewIdResourceName: String): Boolean = listOf(
        "conversation_contact_name",
        "conversation_text_row",
        "message_text",
    ).any { base ->
        viewIdResourceName == "com.whatsapp:id/$base" || viewIdResourceName == "com.whatsapp.w4b:id/$base"
    }

    private fun matches(actual: String, base: String, packageId: String): Boolean = when (packageId) {
        "com.whatsapp" -> actual == "com.whatsapp:id/$base"
        "com.whatsapp.w4b" -> actual == "com.whatsapp.w4b:id/$base"
        else -> false
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
