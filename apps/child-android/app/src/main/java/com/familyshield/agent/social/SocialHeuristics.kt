package com.familyshield.agent.social

/**
 * Pure heuristics for the accessibility social capture (Feature #2/#17): picking the likely
 * contact and message candidate out of the visible text nodes, plus the debounce keying that
 * rate-limits tree walks per app. NOTE: simplest heuristics — the message is the LONGEST text
 * node, the contact is the FIRST short single-line node that is not the message body (on a
 * WhatsApp-style chat screen the toolbar title/contact name precedes message bubbles).
 */
object SocialHeuristics {

    /** Max length of a node still considered a contact/title candidate. */
    const val MAX_CONTACT_LENGTH: Int = 32

    /** Default per-package capture debounce window (AccessibilityMonitorService spec). */
    const val DEBOUNCE_WINDOW_MS: Long = 1500L

    /** Map key used to remember the last capture time per app. */
    fun debounceKey(appKey: String): String = appKey

    /** True when a capture for [debounceKey] is due: never captured, or [windowMs] have passed. */
    fun shouldCapture(lastEventAtMs: Long?, nowMs: Long, windowMs: Long = DEBOUNCE_WINDOW_MS): Boolean =
        lastEventAtMs == null || nowMs - lastEventAtMs >= windowMs

    /** Maps the resolved foreground package (or event package fallback) to `(packageId, appKey)`. */
    fun resolveMonitoredApp(foregroundPackage: String?, eventPackage: String?): Pair<String, String>? {
        for (candidate in listOf(foregroundPackage, eventPackage)) {
            val pkg = candidate?.takeIf { it.isNotBlank() } ?: continue
            val appKey = MonitoredApps.appKeyFor(pkg) ?: continue
            return pkg to appKey
        }
        return null
    }

    /** True when [node] looks like UI chrome/timestamps rather than message content. */
    private fun isUiNoise(node: String): Boolean {
        val lower = node.lowercase()
        if (lower in UI_CHROME_LABELS) return true
        if (TIME_STAMP_RE.matches(lower)) return true
        return false
    }

    /**
     * Returns `(contact, messages)` from [texts]. Keeps [extractContactAndMessage]'s longest bubble
     * first, and also appends the newest non-noise candidate when different so a long older bubble
     * cannot shadow a shorter incoming/outgoing message in the same chat.
     */
    fun extractCandidates(texts: List<String>): Pair<String?, List<String>> {
        val cleaned = texts.map { it.trim() }.filter { it.isNotEmpty() }
        if (cleaned.isEmpty()) return null to emptyList()
        val (contact, longest) = extractContactAndMessage(cleaned)
        val result = ArrayList<String>(2)
        if (!longest.isNullOrBlank() && !isUiNoise(longest)) {
            result.add(longest)
        }
        val newest = cleaned.lastOrNull {
            it != contact &&
                it != longest &&
                it.length >= MIN_NEWEST_CANDIDATE_CHARS &&
                !isUiNoise(it)
        }
        if (newest != null) result.add(newest)
        if (result.isEmpty() && !longest.isNullOrBlank()) result.add(longest)
        return contact to result
    }

    private const val MIN_NEWEST_CANDIDATE_CHARS = 3
    private val TIME_STAMP_RE = Regex("^\\d{1,2}:\\d{2}(\\s*[ap]m)?$")
    private val UI_CHROME_LABELS = setOf(
        "typing...", "typing…", "online", "today", "yesterday", "type a message", "message",
        "search", "delivered", "read", "sent", "unread",
    )

    /**
     * Returns (contact, message) from the visible [texts] in document order. The message is the
     * longest non-blank node; the contact is the first node of 2..[MAX_CONTACT_LENGTH] chars,
     * single line, different from the message. Either side can be null.
     */
    fun extractContactAndMessage(texts: List<String>): Pair<String?, String?> {
        val cleaned = texts.map { it.trim() }.filter { it.isNotEmpty() }
        if (cleaned.isEmpty()) return null to null
        val message = cleaned.maxByOrNull { it.length }
        val contact = cleaned.firstOrNull {
            it != message && it.length in 2..MAX_CONTACT_LENGTH && !it.contains('\n')
        }
        return contact to message
    }
}
