package com.familyshield.agent.setup

import com.familyshield.agent.security.normalizeDigits

fun normalizePairingCode(value: String): String? =
    normalizeDigits(value)?.takeIf { it.length == 6 && it.all { digit -> digit in '0'..'9' } }
