package com.familyshield.agent.comms

/**
 * Pure helpers for the Feature #27 contact allowlist: normalizing phone numbers and deciding
 * whether a number is "unknown" (raises an unknown_contact alert). NOTE: normalization strips
 * every non-digit; country-code tolerance is a suffix match — two normalized numbers match when
 * one ends with the other, as long as both keep at least [MIN_MATCH_DIGITS] digits (so "5551234"
 * matches "+1 202 555-1234" but not "234").
 */
object Allowlist {

    /** Minimum digit count for a suffix (country-code tolerant) match. */
    const val MIN_MATCH_DIGITS: Int = 7

    /** Minimum digits for a number to be considered a real phone number (and alertable). */
    const val MIN_NUMBER_DIGITS: Int = 5

    /** Returns [raw] with all non-digits removed ("+1 (202) 555-0123" -> "12025550123"). */
    fun normalizeNumber(raw: String): String = raw.filter { it.isDigit() }

    /** True when [number] matches an allowlist entry exactly or by country-code suffix. */
    fun isAllowed(number: String, allowlist: List<String>): Boolean {
        val n = normalizeNumber(number)
        if (n.isEmpty()) return true // NOTE: nothing to judge (e.g. a name) — never alerts.
        return allowlist.any { entry ->
            val e = normalizeNumber(entry)
            when {
                e.isEmpty() -> false
                e == n -> true
                n.length >= MIN_MATCH_DIGITS && e.length >= MIN_MATCH_DIGITS &&
                    (n.endsWith(e) || e.endsWith(n)) -> true
                else -> false
            }
        }
    }

    /**
     * Feature #27 decision: [number] is alertable when the allowlist is NON-EMPTY (an empty list
     * means monitoring is disabled -> no alerts), the number has at least [MIN_NUMBER_DIGITS]
     * digits, and it does not match any allowlist entry.
     */
    fun isUnknownContact(number: String, allowlist: List<String>): Boolean {
        if (allowlist.isEmpty()) return false
        val n = normalizeNumber(number)
        if (n.length < MIN_NUMBER_DIGITS) return false
        return !isAllowed(number, allowlist)
    }
}
