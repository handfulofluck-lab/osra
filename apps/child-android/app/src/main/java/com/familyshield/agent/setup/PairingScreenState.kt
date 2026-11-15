package com.familyshield.agent.setup

/**
 * #728 (UI/UX Bureau's pairing design, 13 Nov): the state the new pairing screen draws, free of Compose so the
 * rules are JVM-tested and the composable is left with nothing to decide.
 *
 * The design asks for six code cells, one optional name field, a button that stays disabled until the code is
 * complete, a waiting state while the parent approves, and **one line** for an error under the cells. Those are
 * decisions, not drawing, so they live here.
 *
 * **The digits are always Western.** A parent reading a code off another screen, and a server that compares
 * `"012345"`, both mean 0–9; an Arabic-Indic ٠–٩ typed into the field would be a different string to the server and
 * the same number to the parent (issue #771's class of bug). [onPaste] and [onDigit] fold them, so the screen never
 * has to.
 */
data class PairingScreenState(
    val digits: String = "",
    val deviceName: String = "",
    val error: String? = null,
    val waiting: Boolean = false,
) {

    /** True when the code is complete and nothing is in flight — the one condition the primary button reads. */
    val canSubmit: Boolean get() = digits.length == CODE_LENGTH && !waiting

    /** Typing one character. Anything that is not a digit is ignored rather than shown. */
    fun onDigit(input: Char): PairingScreenState {
        if (waiting) return this
        val digit = westernDigit(input) ?: return this
        if (digits.length >= CODE_LENGTH) return this
        return copy(digits = digits + digit, error = null)
    }

    /**
     * Pasting into the field: the OS hands over whatever is on the clipboard, so the six digits are taken out of it
     * and everything else is dropped — a copied message that contains the code fills the cells, and one that does
     * not leaves them alone instead of half-filling them.
     */
    fun onPaste(text: String): PairingScreenState {
        if (waiting) return this
        val digitsOnly = text.mapNotNull { westernDigit(it) }.take(CODE_LENGTH)
        if (digitsOnly.length != CODE_LENGTH) return this
        return copy(digits = digitsOnly, error = null)
    }

    /** Backspace: the last cell empties, and an error line goes with it. */
    fun onBackspace(): PairingScreenState {
        if (waiting) return this
        if (digits.isEmpty()) return this
        return copy(digits = digits.dropLast(1), error = null)
    }

    /** The optional phone name ("Alex's phone"). Trimmed, and capped so a paste cannot bloat the claim. */
    fun onName(text: String): PairingScreenState =
        if (waiting) this else copy(deviceName = text.take(NAME_MAX_LENGTH), error = null)

    /** The button was pressed: nothing else may change until the claim answers. */
    fun submitting(): PairingScreenState =
        if (!canSubmit) this else copy(waiting = true, error = null)

    /** The claim failed. The waiting state ends and the message appears **under the cells**, never as a toast. */
    fun failed(message: String): PairingScreenState = copy(waiting = false, error = message)

    /** The parent approved: the screen has nothing left to draw. */
    fun approved(): PairingScreenState = copy(waiting = false, error = null)

    companion object {
        const val CODE_LENGTH = 6
        const val NAME_MAX_LENGTH = 40

        /** Folds the two Arabic-Indic digit ranges to 0–9; every other character is not a digit for this field. */
        fun westernDigit(input: Char): Char? = when (input) {
            in '0'..'9' -> input
            in '\u0660'..'\u0669' -> ('0' + (input - '\u0660'))
            in '\u06F0'..'\u06F9' -> ('0' + (input - '\u06F0'))
            else -> null
        }
    }
}
