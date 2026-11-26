package com.familyshield.agent.social

import kotlin.math.abs

/** Bounded, occurrence-aware dedupe shared by screen and notification captures. */
class ScanDedupeTracker {
    private data class Receipt(val source: String, val occurrenceId: String, val atMs: Long)

    private val recent = LinkedHashMap<String, MutableList<Receipt>>()

    fun shouldEnqueue(
        app: String,
        contact: String?,
        text: String,
        nowMs: Long,
        source: String,
        occurrenceId: String,
    ): Boolean {
        prune(nowMs)
        val hash = SocialScanQueue.dedupeHash(app, contact, text)
        val receipts = recent[hash].orEmpty().toMutableList()
        if (receipts.any { it.source == source && it.occurrenceId == occurrenceId }) return false
        if (receipts.any { it.source != source && abs(nowMs - it.atMs) <= CROSS_SOURCE_DEDUPE_WINDOW_MS }) {
            return false
        }
        receipts += Receipt(source, occurrenceId, nowMs)
        recent.remove(hash)
        recent[hash] = receipts
        while (recent.size > MAX_CONTENT_HASHES) {
            val oldest = recent.keys.firstOrNull() ?: break
            recent.remove(oldest)
        }
        return true
    }

    fun prune(nowMs: Long) {
        recent.values.forEach { receipts ->
            receipts.removeAll { nowMs - it.atMs > DEDUPE_WINDOW_MS }
        }
        recent.entries.removeAll { it.value.isEmpty() }
    }

    companion object {
        const val DEDUPE_WINDOW_MS: Long = SocialScanQueue.DEDUPE_WINDOW_MS
        const val CROSS_SOURCE_DEDUPE_WINDOW_MS: Long = DEDUPE_WINDOW_MS
        private const val MAX_CONTENT_HASHES: Int = 512
    }
}
