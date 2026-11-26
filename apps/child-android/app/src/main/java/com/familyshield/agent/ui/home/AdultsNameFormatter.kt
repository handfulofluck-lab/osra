package com.familyshield.agent.ui.home

/**
 * F7 (#1179) & Arabic Language Bureau (7191839045): formats the child's parents/guardians list
 * without gendered verb/adjective agreement, wrapping every name in Unicode FSI...PDI (`\u2068...\u2069`).
 *
 * Arabic rules (7191839045 §1) & Claude lead (#1191 7197409788):
 * - 0 adults -> caller-provided fallback («أهلي» child speaking, «أهلك» app addressing child)
 * - 1 adult  -> `{name1}`
 * - 2 adults -> `{name1} و{name2}` (space before «و», none after)
 * - 3 adults -> `{name1} و{name2} و{name3}` («و» before each name, no commas)
 * - 4+ adults -> caller-provided generic fallback so no adult is silently dropped (e.g. SOS)
 */
object AdultsNameFormatter {

    private const val FSI: Char = '\u2068'
    private const val PDI: Char = '\u2069'
    private const val LRI: Char = '\u2066'

    fun firstStrongIsolate(value: String): String = "$FSI${value.trim()}$PDI"

    fun ltrIsolate(value: String): String = "$LRI${value.trim()}$PDI"

    fun format(
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
