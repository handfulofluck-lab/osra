package com.familyshield.agent.enforcement

import com.familyshield.agent.data.WindowKind
import com.familyshield.agent.data.WindowReason

/**
 * Issue #473: the one line the block screen adds when a window is what is holding the app shut.
 *
 * **Localised by the caller, decided here.** The first version built "Bedtime", "School hours" and the
 * whole template in Kotlin, so an Arabic phone could never show Arabic (review point 4). The screen now
 * resolves `block_window_bedtime`, `block_window_school` and `block_window_line` from resources and passes
 * them in; this function still owns the *decision* — which window, which label, whether a line at all —
 * so a JVM row pins it without Android.
 *
 * **Only windows appear.** A pause, an explicit `block`, a `time_limit` and the blocklist arrive with no
 * [WindowReason] (`RuleEngine.evaluateWithReason` answers null for each), so this returns null and the
 * screen keeps today's copy. Naming a window there would be a promise the rules do not keep.
 *
 * **Each value is direction-isolated (#506).** On an Arabic phone the rendered sentence is RTL, but a
 * routine's name is whatever the family typed — often English. Without isolation the Unicode bidi
 * algorithm lets that name and the digits after it trade places, and «محجوب بسبب Homework حتى 23:50»
 * came out as «محجوب بسبب Homework 23:50 حتى» on the Flip4. Wrapping **both** the label and the time in
 * FSI…PDI (U+2068 / U+2069) makes each one a self-contained run whose direction comes from its own first
 * strong character, so the template's order survives whatever the name is. FSI rather than LRI/RLI
 * because the direction is not known here: it belongs to the family's text, not to us.
 *
 * Done by hand rather than with `android.text.BidiFormatter` on purpose: this object stays pure so the
 * rows in `BlockWindowCopyTest` pin the exact emitted string on the JVM, with no Android runtime.
 */
object BlockWindowCopy {

    private const val FSI = '\u2068'   // FIRST STRONG ISOLATE
    private const val PDI = '\u2069'   // POP DIRECTIONAL ISOLATE

    /**
     * The sentence for [window], or null when nothing should be added.
     *
     * @param bedtime the localised "Bedtime"
     * @param schoolHours the localised "School hours"
     * @param template the localised "Blocked by %1$s until %2$s"
     */
    fun line(
        window: WindowReason?,
        bedtime: String,
        schoolHours: String,
        template: String,
    ): String? {
        if (window == null) return null
        val label = when (window.kind) {
            WindowKind.ROUTINE -> window.name?.takeIf { it.isNotBlank() } ?: return null
            WindowKind.BEDTIME -> bedtime
            WindowKind.SCHOOL -> schoolHours
        }
        return String.format(template, isolate(label), isolate(window.endsAt))
    }

    /** A self-contained run: its direction comes from its own first strong character, not the sentence's. */
    private fun isolate(value: String): String = "$FSI$value$PDI"
}
