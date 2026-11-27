package com.familyshield.agent.ui.theme

/**
 * Runtime feature switches for the #1179 UX final screens, each defaulting to the new screen
 * while preserving the previous screen as an instant fallback.
 */
object ChildUxFlags {
    /** C-05 First run (permissions before pairing #1174 + transparency card + agreement last); false restores legacy order. */
    @Volatile
    var c05FirstRunEnabled: Boolean = true

    /**
     * Issue #1236 (after-test contingency): default-off switch for Xiaomi/MIUI fallback when MIUI
     * still aborts Lock/Block/Guard Activity starts (`TYPE_ACCESSIBILITY_OVERLAY` backstop + daily
     * parent alert) and separate `capabilities.grants.miui_popup` (`confirmed_unverified`) reporting.
     */
    @Volatile
    var miuiLockBackstopEnabled: Boolean = false
}
