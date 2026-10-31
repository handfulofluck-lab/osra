package com.familyshield.agent.social

/**
 * Plan 2.6 — the pure rules of the durable scan queue: how many rows a flush takes, when a row is
 * given up on, and which notification fields make a capture. JVM-tested; [SocialScanQueue] and
 * [com.familyshield.agent.services.NotificationCaptureService] apply them.
 */
object ScanQueuePolicy {
    /** Rows per flush — bounded so a day's backlog drains in a few network bursts, not one huge one. */
    const val BATCH_SIZE: Int = 50

    /**
     * #490: captures per `POST /v1/social/scan`. A flush of [BATCH_SIZE] rows goes out in requests of
     * this many, not one request per row, so the radio wakes once per six captures. Must match the
     * server's `SCAN_BATCH_MAX`, which refuses a larger body as a whole.
     */
    const val ITEMS_PER_REQUEST: Int = 6

    /** A row that failed this many POSTs is poison (a 4xx that will never succeed) and is dropped. */
    const val MAX_ATTEMPTS: Int = 8

    /** A capture older than this is no longer worth a scan: the parent would get a stale alert. */
    const val MAX_AGE_MS: Long = 48 * 60 * 60 * 1000

    /** Whether a row with [attempts] failed tries created at [createdAtMs] should still be sent at [nowMs]. */
    fun shouldKeep(attempts: Int, createdAtMs: Long, nowMs: Long): Boolean =
        attempts < MAX_ATTEMPTS && nowMs - createdAtMs <= MAX_AGE_MS

    /** Flush is retried later when any row failed for a reason that can heal (network); 4xx counts against the row. */
    fun retryLater(anyNetworkFailure: Boolean, remaining: Int): Boolean = anyNetworkFailure && remaining > 0

    const val SOURCE_SCREEN = "screen"
    const val SOURCE_NOTIFICATION = "notification"

    /**
     * Builds the capture from a notification's fields: [title] is the sender (or the group), the
     * message is the newest of [messages] (MessagingStyle) when present, else [bigText]/[text].
     * Returns null for notifications that carry no message (summaries, "checking for new messages",
     * calls, media controls), so they never reach the queue.
     */
    fun fromNotification(title: CharSequence?, text: CharSequence?, bigText: CharSequence?, messages: List<CharSequence?>): Pair<String?, String>? {
        val contact = title?.toString()?.trim()?.takeIf { it.isNotEmpty() }
        val body = (messages.lastOrNull { !it.isNullOrBlank() } ?: bigText?.takeIf { it.isNotBlank() } ?: text)
            ?.toString()?.trim().orEmpty()
        if (body.isEmpty()) return null
        val lower = body.lowercase()
        if (NOISE.any { lower == it || lower.startsWith(it) }) return null
        // A collapsed group says "3 new messages" — a leading count defeats the literal NOISE list
        // above (none of those entries starts with a digit), so the placeholder has to be matched as
        // a shape. Without this, a summary becomes a scan row with the sender as the group and the
        // count as the message (plan 2.6).
        if (NOISE_PATTERN.matches(lower)) return null
        return contact to body
    }

    /** "3 new messages", "12 new messages from Work" — the collapsed-notification placeholders. */
    private val NOISE_PATTERN = Regex("^\\d+\\s+new messages?(\\s+from\\s+.+)?$")

    private val NOISE = listOf(
        "checking for new messages", "incoming voice call", "incoming video call", "ongoing voice call",
        "ongoing video call", "missed voice call", "missed video call", "you may have new messages",
        "new messages", "backup in progress", "restoring media", "finished backup",
    )
}
