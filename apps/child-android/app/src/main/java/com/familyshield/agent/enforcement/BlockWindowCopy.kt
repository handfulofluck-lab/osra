package com.familyshield.agent.enforcement

import com.familyshield.agent.data.WindowKind
import com.familyshield.agent.data.WindowReason

/**
 * Issue #473: the one line the block screen adds when a window is what is holding the app shut.
 *
 * Pure and Android-free so a JVM row can pin it: the screen around it is Compose and needs a device, but
 * the sentence — and which reason produces which sentence — is a decision.
 *
 * **Why only windows appear.** A pause, an explicit `block`, a `time_limit` and the blocklist arrive with
 * no [WindowReason] (`RuleEngine.windowFor` answers null for each), so this returns null and the screen
 * keeps today's copy. Naming a window there would be a promise the rules do not keep: a blocked app does
 * not open at 15:00 because school hours ended.
 */
object BlockWindowCopy {

    /**
     * The sentence for [window], or null when nothing should be added.
     *
     * A routine's name is the family's own text and is used verbatim; the two screen-time windows are
     * named in the app's own words because the phone, not the family, owns those concepts.
     */
    fun line(window: WindowReason?): String? {
        if (window == null) return null
        val label = when (window.kind) {
            WindowKind.ROUTINE -> window.name?.takeIf { it.isNotBlank() } ?: return null
            WindowKind.BEDTIME -> "Bedtime"
            WindowKind.SCHOOL -> "School hours"
        }
        return "Blocked by $label until ${window.endsAt}"
    }
}
