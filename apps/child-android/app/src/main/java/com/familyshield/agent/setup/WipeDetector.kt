package com.familyshield.agent.setup

/**
 * Issue #81: `adb shell pm clear` wipes the agent's data although device admin is active, and the wipe takes
 * the device token with it, so the phone cannot report it. What it leaves behind is recognisable: the admin
 * grant lives in the system, not in our data, so it survives; the pairing and the parent PIN do not.
 *
 * - A fresh install has no admin grant.
 * - A parent's Re-pair (behind the PIN) clears the pairing but keeps the PIN.
 * - An uninstall needs the admin removed first.
 *
 * So "admin active, not paired, no PIN" means the data was cleared. The phone says so on its next pairing
 * claim (`dataCleared`), the parent's Allow card shows it, and the Allow records a `tamper` alert.
 */
object WipeDetector {
    fun dataCleared(adminActive: Boolean, paired: Boolean, pinConfigured: Boolean): Boolean =
        adminActive && !paired && !pinConfigured
}
