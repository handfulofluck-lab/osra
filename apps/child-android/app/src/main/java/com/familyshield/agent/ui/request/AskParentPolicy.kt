package com.familyshield.agent.ui.request

/** Payload posted to `/v1/alerts/internal` from C-03 Ask a parent (#1179, G2/G3). */
data class AskTimeRequestPayload(
    val title: String,
    val body: String,
    val metadata: Map<String, String>,
    val dedupeKey: String,
)

/**
 * Pure JVM policy for C-03 Ask a parent (#1179):
 * - G3 (Karim 26 Nov 17:02): whole-day screen time only (no per-app scope switch in this cut).
 * - G2 (Claude 17:28 + Codex 17:37): only 15 or 30 minutes are offered and emitted (never 60).
 * - #1185 (Karim 26 Nov 17:04): no free-text child note field.
 * - One request at a time + stable idempotency dedupe key per session so repeated taps create one row.
 * - F7 adults formatter matching Arabic Language Bureau 7191839045.
 */
object AskParentPolicy {

    /** Only 15 and 30 minutes are valid for this cut (Codex 7193611894). */
    val ALLOWED_MINUTES: List<Int> = listOf(15, 30)

    private const val FSI: Char = '\u2068'
    private const val LRI: Char = '\u2066'
    private const val PDI: Char = '\u2069'

    fun firstStrongIsolate(value: String): String = "$FSI${value.trim()}$PDI"

    fun ltrIsolate(value: String): String = "$LRI${value.trim()}$PDI"

    fun normalizeMinutes(minutes: Int): Int =
        if (minutes in ALLOWED_MINUTES) minutes else ALLOWED_MINUTES.first()

    /** True only when a daily limit exists, no request is already waiting, and no send is in flight. */
    fun canSend(
        hasDailyLimit: Boolean,
        hasPendingWaiting: Boolean,
        isSending: Boolean,
    ): Boolean = hasDailyLimit && !hasPendingWaiting && !isSending

    /** Exact G2 wire contract (`requestType: "time"`, decimal string `minutes`, `reason: "daily_limit"`). */
    fun buildTimeRequest(
        requestedMinutes: Int,
        idempotencyToken: String,
    ): AskTimeRequestPayload {
        val mins = normalizeMinutes(requestedMinutes)
        val token = idempotencyToken.trim().ifEmpty { "default" }
        return AskTimeRequestPayload(
            title = "Screen time requested",
            body = "Child asked for $mins more minutes of screen time",
            metadata = mapOf(
                "requestType" to "time",
                "minutes" to mins.toString(),
                "reason" to "daily_limit",
            ),
            dedupeKey = "child_time_request:$token",
        )
    }

    /** Formats 0 / 1 / 2 / 3 adult names per F7 & Arabic Language Bureau 7191839045; 4+ uses generic fallback. */
    fun formatAdults(
        names: List<String>,
        fallback: String,
        isArabic: Boolean,
    ): String {
        val clean = names
            .asSequence()
            .map { it.trim() }
            .filter { it.isNotEmpty() }
            .distinct()
            .map { firstStrongIsolate(it) }
            .toList()
        return when (clean.size) {
            0 -> fallback
            1 -> clean[0]
            2 -> if (isArabic) "${clean[0]} و${clean[1]}" else "${clean[0]} and ${clean[1]}"
            3 -> if (isArabic) {
                "${clean[0]} و${clean[1]} و${clean[2]}"
            } else {
                "${clean[0]}, ${clean[1]} and ${clean[2]}"
            }
            else -> fallback
        }
    }
}
