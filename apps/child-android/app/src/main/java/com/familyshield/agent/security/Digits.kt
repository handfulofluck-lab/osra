package com.familyshield.agent.security

/**
 * The three digit forms the Bureaus accept (#771): Western `0–9`, Arabic-Indic
 * `٠–٩` (U+0660–U+0669) and Extended Arabic-Indic `۰–۹` (U+06F0–U+06F9). An Arabic or Urdu keyboard
 * types the latter two, while the product shows Western digits everywhere. Every PIN, pairing code
 * and number is normalised here before any check, hash, comparison or request, so the same digits
 * are one value whichever keyboard typed them.
 */
object Digits {

    fun normalize(value: String): String = buildString(value.length) {
        for (ch in value) append(normalizeChar(ch))
    }

    /** True when every character is a Western digit after [normalize]. `isDigit` also accepts `½`, `②`, … */
    fun isAsciiDigits(value: String): Boolean = value.isNotEmpty() && normalize(value).all { it in '0'..'9' }

    private fun normalizeChar(ch: Char): Char = when (ch) {
        in '\u0660'..'\u0669' -> '0' + (ch - '\u0660')
        in '\u06F0'..'\u06F9' -> '0' + (ch - '\u06F0')
        else -> ch
    }
}
