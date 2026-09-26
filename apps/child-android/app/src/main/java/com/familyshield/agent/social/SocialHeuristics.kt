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
