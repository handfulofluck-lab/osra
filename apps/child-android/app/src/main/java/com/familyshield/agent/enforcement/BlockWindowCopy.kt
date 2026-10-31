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
 */
object BlockWindowCopy {

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
        return String.format(template, label, window.endsAt)
    }
}
