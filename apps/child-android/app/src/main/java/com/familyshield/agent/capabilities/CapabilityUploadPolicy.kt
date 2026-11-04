package com.familyshield.agent.capabilities

/**
 * ADR-0034 amendment A2: a grant change reaches the server as **one** request, not at the next period.
 *
 * The phone is resumed every time the child (or a parent in the room) leaves Settings, so "upload on resume"
 * would be a request per resume — that is the idle budget #353/#367 exists to protect. So a resume uploads
 * only when the report **differs** from the last one the server accepted, and the difference is decided here,
 * on a stable fingerprint rather than on the object's identity.
 *
 * Pure, so the fingerprint's determinism is a JVM row: the same facts must produce the same string, and any
 * change in any grant, feature or profile must change it. Maps are rendered with sorted keys and both maps and
 * lists are wrapped, so `{a=1}{b=2}` cannot collide with a single value that happens to read the same way.
 */
object CapabilityUploadPolicy {

    /** A stable, compact fingerprint of a report — no JSON dependency, so it runs in the unit suite. */
    fun fingerprint(report: Map<String, Any?>): String = render(report)

    private fun render(value: Any?): String = when (value) {
        is Map<*, *> -> value.entries
            .sortedBy { it.key.toString() }
            .joinToString(";", "{", "}") { "${it.key}=${render(it.value)}" }
        is List<*> -> value.joinToString(",", "[", "]") { render(it) }
        null -> "-"
        // A length prefix, not escaping: without it a value containing the separators renders exactly like
        // two entries — `{a=1;b=2}` is `mapOf("a" to "1;b=2")` and `mapOf("a" to "1", "b" to "2")` at once,
        // and a real change would be swallowed as "unchanged". Pinned by
        // `CapabilityUploadPolicyTest > a value that reads like the separators…`.
        is String -> "${value.length}:$value"
        else -> value.toString()
    }
}
