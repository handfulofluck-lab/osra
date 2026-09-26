package com.familyshield.agent.social

/**
 * Pure PII redaction for captured social/chat text (Feature #2/#17) BEFORE anything leaves the
 * device: phone numbers -> [phone], email addresses -> [email], runs of 4+ digits -> [num].
 * NOTE: simplest regex heuristics — a date like "2024-01-15" also matches the phone pattern and
 * becomes [phone]; over-redaction is the safe failure mode here. Applying the replacements in
 * order (email, phone, digit runs) makes [redact] idempotent: the replacement tokens contain no
 * digits or email/phone characters.
 */
object TextRedaction {

    private val EMAIL = Regex("[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\\.[A-Za-z]{2,}")
    // NOTE: needs at least 8 chars (start digit + 6 separators/digits + end digit); short codes survive.
    private val PHONE = Regex("\\+?\\d[\\d().\\-\\s]{6,}\\d")
    private val DIGIT_RUN = Regex("\\d{4,}")

    /** Returns [text] with emails, phone numbers and 4+ digit runs replaced by fixed tokens. */
    fun redact(text: String): String =
        text
            .replace(EMAIL, "[email]")
            .replace(PHONE, "[phone]")
            .replace(DIGIT_RUN, "[num]")
}
