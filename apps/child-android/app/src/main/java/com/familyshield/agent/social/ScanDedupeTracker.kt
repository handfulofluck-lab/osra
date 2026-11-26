package com.familyshield.agent.social

import kotlin.math.abs

/** Bounded occurrence and cross-source dedupe, recorded only after durable queue admission. */
class ScanDedupeTracker {
    private data class Receipt(val source: String, val occurrenceId: String?, val atMs: Long)

    private val recent = LinkedHashMap<String, MutableList<Receipt>>()

    fun canEnqueue(
        app: String,
        contact: String?,
        text: String,
        nowMs: Long,
        source: String,
        occurrenceId: String?,
    ): Boolean {
        prune(nowMs)
        val receipts = recent[canonicalHash(app, contact, text)].orEmpty()
        if (occurrenceId == null && receipts.any { it.source == source }) return false
        if (occurrenceId != null && receipts.any { it.source == source && it.occurrenceId == occurrenceId }) return false
        return receipts.none { it.source != source && abs(nowMs - it.atMs) <= CROSS_SOURCE_DEDUPE_WINDOW_MS }
    }

    fun record(
        app: String,
        contact: String?,
        text: String,
        nowMs: Long,
        source: String,
        occurrenceId: String?,
    ) {
        prune(nowMs)
        val hash = canonicalHash(app, contact, text)
        val receipts = recent[hash].orEmpty().toMutableList()
        receipts += Receipt(source, occurrenceId, nowMs)
        recent.remove(hash)
        recent[hash] = receipts
        while (recent.size > MAX_CONTENT_HASHES) {
            val oldest = recent.keys.firstOrNull() ?: break
            recent.remove(oldest)
        }
    }

    fun prune(nowMs: Long) {
        recent.values.forEach { receipts -> receipts.removeAll { nowMs - it.atMs > DEDUPE_WINDOW_MS } }
        recent.entries.removeAll { it.value.isEmpty() }
    }

    private fun canonicalHash(app: String, contact: String?, text: String): String =
        SocialScanQueue.dedupeHash(app, contact?.trim(), text.trim().replace(Regex("\\s+"), " "))

    companion object {
        const val DEDUPE_WINDOW_MS: Long = SocialScanQueue.DEDUPE_WINDOW_MS
        const val CROSS_SOURCE_DEDUPE_WINDOW_MS: Long = DEDUPE_WINDOW_MS
        private const val MAX_CONTENT_HASHES: Int = 512
    }
}
