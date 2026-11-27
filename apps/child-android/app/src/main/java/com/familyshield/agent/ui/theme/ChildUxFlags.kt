package com.familyshield.agent.ui.theme

/**
 * Runtime feature switches for the #1179 UX final screens, each defaulting to the new screen
 * while preserving the previous screen as an instant fallback.
 */
object ChildUxFlags {
    /** C-02 Time's up / blocked screen; when false, [com.familyshield.agent.enforcement.BlockActivity] renders the legacy fallback. */
    @Volatile
    var c02BlockedScreenEnabled: Boolean = true
}
