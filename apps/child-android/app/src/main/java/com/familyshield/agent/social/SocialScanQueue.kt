package com.familyshield.agent.social

import com.familyshield.agent.comms.Allowlist
import com.familyshield.agent.data.AgentSettings
import com.familyshield.agent.data.RuleRepository
import com.familyshield.agent.network.ApiService
import com.familyshield.agent.network.dto.AlertDto
import com.familyshield.agent.network.dto.SocialScanBatchDto
import com.familyshield.agent.network.dto.SocialScanDto
import java.security.MessageDigest
import javax.inject.Inject
import javax.inject.Singleton
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock

/**
 * Feature #2/#17 social scan queue: batches redacted captures for 3 s, dedupes by content hash,
 * caps the send rate at [MAX_SENDS_PER_MINUTE] and HMAC-POSTs the batch, six captures per request
 * (#490), to POST /v1/social/scan (the server runs the AI scan and raises alerts). On 200 nothing extra happens
 * here — flagged content surfaces as server-side alerts. A numeric contact (e.g. an unsaved
 * WhatsApp number) is also checked against the Feature #27 allowlist; an unknown number raises a
 * throttled unknown_contact alert (1 per hour per number, allowlist empty = disabled).
 */
@Singleton
class SocialScanQueue @Inject constructor(
    private val api: ApiService,
    private val settings: AgentSettings,
    private val rules: RuleRepository,
    private val dao: com.familyshield.agent.data.db.PendingScanDao,
    @dagger.hilt.android.qualifiers.ApplicationContext private val context: android.content.Context,
) {
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    private val mutex = Mutex()
    private val recentHashes = LinkedHashMap<String, Long>() // insertion-ordered for pruning
    private val sendTimestamps = ArrayDeque<Long>()
    private val lastAlertAt = HashMap<String, Long>()
    private var flushJob: Job? = null

    /**
     * Queues one capture **durably** (plan 2.6: a Room row, so a kill, a reboot or an offline stretch
     * loses nothing) and flushes after [FLUSH_DELAY_MS] of quiet. Dedupe and the send-rate cap are
     * applied before the row is written. [source] is where the text came from (screen / notification).
     */
    fun enqueue(app: String, contact: String?, text: String, nowMs: Long = System.currentTimeMillis(), source: String = ScanQueuePolicy.SOURCE_SCREEN) {
        if (text.isBlank()) return
        val hash = dedupeHash(app, contact, text)
        scope.launch {
            mutex.withLock {
                val last = recentHashes[hash]
                if (last != null && nowMs - last < DEDUPE_WINDOW_MS) return@withLock
                if (!withinRateLimit(sendTimestamps, nowMs, RATE_WINDOW_MS, MAX_SENDS_PER_MINUTE)) {
                    return@withLock // NOTE: over rate — drop; the next user action re-captures.
                }
                recentHashes[hash] = nowMs
                pruneLocked(nowMs)
                runCatching {
                    dao.insert(com.familyshield.agent.data.db.PendingScanEntity(app = app, contact = contact, text = text, source = source, createdAt = nowMs))
                }
                if (flushJob == null) {
                    flushJob = scope.launch { delay(FLUSH_DELAY_MS); flush() }
                }
            }
        }
    }

    /**
     * Sends the oldest queued rows (serialized), [ScanQueuePolicy.ITEMS_PER_REQUEST] per request (#490).
     * A row is deleted when the server answers `ok` for it, kept with `attempts + 1` otherwise, and purged by [ScanQueuePolicy.shouldKeep]'s limits; when a network failure leaves
     * rows behind, [ScanFlushWorker] is scheduled to retry under a network constraint.
     */
    suspend fun flush() {
        mutex.withLock {
            flushJob?.cancel()
            flushJob = null
            val now = System.currentTimeMillis()
            runCatching { dao.purge(now - ScanQueuePolicy.MAX_AGE_MS, ScanQueuePolicy.MAX_ATTEMPTS) }
            val batch = runCatching { dao.oldest(ScanQueuePolicy.BATCH_SIZE) }.getOrDefault(emptyList())
            if (batch.isEmpty()) return@withLock
            val childId = settings.childId()
            val deviceId = settings.deviceId()
            if (childId == null || deviceId == null) return@withLock // not paired: keep the rows for after pairing
            // #490: one request per ITEMS_PER_REQUEST rows, not one per row; each row is settled by its
            // own answer, so one bad capture never drops the others.
            val outcome = ScanBatchSender<com.familyshield.agent.data.db.PendingScanEntity>(
                toDto = { row ->
                    SocialScanDto(childId = childId, deviceId = deviceId, app = row.app, contact = row.contact, text = row.text, source = row.source)
                },
                post = { items -> api.postSocialScanBatch(SocialScanBatchDto(items)).results },
                isPermanentRejection = { e -> e is retrofit2.HttpException && e.code() in 400..499 && e.code() != 429 },
            ).send(batch)
            for (row in outcome.sent) {
                sendTimestamps.addLast(System.currentTimeMillis())
                runCatching { dao.delete(row.id) }
                row.contact?.let { maybeAlertUnknownContact(it, row.app) }
            }
            // The server will never take these: count them down to the drop.
            for (row in outcome.rejected) runCatching { dao.bumpAttempts(row.id) }
            for (row in outcome.failed) runCatching { dao.bumpAttempts(row.id) }
            val networkFailure = outcome.failed.isNotEmpty()
            val remaining = runCatching { dao.count() }.getOrDefault(0)
            if (ScanQueuePolicy.retryLater(networkFailure, remaining)) ScanFlushWorker.scheduleRetry(context)
        }
    }

    /** Rows waiting to be sent (for the status screen and tests). */
    suspend fun pendingCount(): Int = runCatching { dao.count() }.getOrDefault(0)

    /** Raises at most one unknown_contact alert per hour for a numeric contact not in the allowlist. */
    private suspend fun maybeAlertUnknownContact(contact: String, app: String) {
        val digits = contact.filter { it.isDigit() }
        if (digits.length < Allowlist.MIN_NUMBER_DIGITS) return // a name, not a number
        val allowlist = rules.contactAllowlist()
        if (!Allowlist.isUnknownContact(contact, allowlist)) return
        val now = System.currentTimeMillis()
        val last = lastAlertAt[digits]
        if (last != null && now - last < ALERT_THROTTLE_MS) return
        lastAlertAt[digits] = now
        val childId = settings.childId() ?: return
        runCatching {
            api.postInternalAlert(
                AlertDto(
                    childId = childId,
                    deviceId = settings.deviceId(),
                    severity = "info",
                    category = "unknown_contact",
                    title = "Unknown contact",
                    body = "Child contacted/received from $digits via $app",
                    metadata = mapOf("contact" to digits),
                ),
            )
        }
    }

    private fun pruneLocked(nowMs: Long) {
        val it = recentHashes.entries.iterator()
        while (it.hasNext()) {
            if (nowMs - it.next().value > DEDUPE_WINDOW_MS) it.remove() else break
        }
        while (sendTimestamps.isNotEmpty() && nowMs - sendTimestamps.first() > RATE_WINDOW_MS) {
            sendTimestamps.removeFirst()
        }
    }

    companion object {
        /** Quiet period before a batch is flushed. */
        const val FLUSH_DELAY_MS: Long = 3000L

        /** A hash is considered a duplicate within this window. */
        const val DEDUPE_WINDOW_MS: Long = 10 * 60_000L

        /** Send-rate cap window. */
        const val RATE_WINDOW_MS: Long = 60_000L

        /** Max POST /v1/social/scan calls per [RATE_WINDOW_MS]. */
        const val MAX_SENDS_PER_MINUTE: Int = 30

        /** Min delay between unknown_contact alerts for the same number. */
        const val ALERT_THROTTLE_MS: Long = 60 * 60_000L

        /** Content hash used for dedupe (SHA-256, first 16 hex chars — collisions only drop a scan). */
        fun dedupeHash(app: String, contact: String?, text: String): String {
            val digest = MessageDigest.getInstance("SHA-256")
                .digest("$app\u0000${contact ?: ""}\u0000$text".toByteArray(Charsets.UTF_8))
            val sb = StringBuilder(16)
            for (i in 0 until 8) sb.append(String.format("%02x", digest[i]))
            return sb.toString()
        }

        /**
         * Pure rate-limit check: true when fewer than [max] of [timestamps] (ascending, millis)
         * fall within ([nowMs] - [windowMs], [nowMs]].
         */
        fun withinRateLimit(timestamps: List<Long>, nowMs: Long, windowMs: Long, max: Int): Boolean {
            val cutoff = nowMs - windowMs
            return timestamps.count { it > cutoff } < max
        }
    }
}
