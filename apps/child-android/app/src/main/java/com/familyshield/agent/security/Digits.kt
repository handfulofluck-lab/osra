package com.familyshield.agent.security

fun normalizeDigits(value: String): String? {
    val normalized = StringBuilder(value.length)
    for (character in value) {
        when (character) {
            in '0'..'9' -> normalized.append(character)
            in '٠'..'٩' -> normalized.append('0' + (character - '٠'))
            in '۰'..'۹' -> normalized.append('0' + (character - '۰'))
            ' ', '‎', '‏', '؜' -> Unit
            else -> return null
        }
    }
    return normalized.toString()
}
