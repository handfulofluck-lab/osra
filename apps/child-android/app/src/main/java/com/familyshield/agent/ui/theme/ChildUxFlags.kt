package com.familyshield.agent.ui.theme

/**
 * Runtime feature switches for the #1179 UX final screens, each defaulting to the new screen
 * while preserving the previous screen as an instant fallback.
 */
object ChildUxFlags {
    /** C-05 First run (permissions before pairing #1174 + transparency card + agreement last); false restores legacy order. */
    @Volatile
    var c05FirstRunEnabled: Boolean = true
}
