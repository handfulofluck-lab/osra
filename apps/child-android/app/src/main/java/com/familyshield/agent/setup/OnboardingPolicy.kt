package com.familyshield.agent.setup

/**
 * Plan item 1.6 — guided, verified onboarding. The pure half: which grants the agent needs, which of
 * them are *required* before pairing may be called complete, the one-line reason the parent sees,
 * and the OEM-specific hint. [PairingActivity] supplies the live state (`granted`) by asking the OS
 * on every resume, so a parent who came back from Settings without granting sees the row still red.
 *
 * Acceptance for 1.6: *pairing cannot complete with a required permission missing.* "Required" is
 * what the product does not work without — the accessibility service (every block and the tamper
 * guard), usage access (limits), display over other apps (the lock), device admin (uninstall
 * protection), the web filter consent (1.4), location (locate / geofences) and Private DNS off a
 * named host (otherwise the web filter is bypassed). Battery exemption and the notification
 * listener (2.6) are recommended: without them the agent is slower, not absent.
 */
object OnboardingPolicy {

    enum class Grant(val title: String, val why: String, val required: Boolean) {
        ACCESSIBILITY("Accessibility service", "Blocks apps, enforces limits and guards the uninstall screens. Nothing works without it.", true),
        USAGE_ACCESS("Usage access", "Counts screen time per app so daily limits and reports are right.", true),
        OVERLAY("Display over other apps", "Shows the lock, pause and PIN screens on top of whatever is open.", true),
        DEVICE_ADMIN("Device admin", "Stops the app being uninstalled without the parent PIN; lets the parent lock the device.", true),
        WEB_FILTER("Web filter (VPN consent)", "Blocks sites and categories, forces SafeSearch, and makes pause-internet real.", true),
        LOCATION("Location (allow all the time)", "Locate the device and geofence alerts; background access keeps it working with the app closed.", true),
        PRIVATE_DNS("Private DNS not set to a provider", "A named Private DNS provider bypasses the web filter. Set it to Automatic or Off.", true),
        BATTERY("Battery: unrestricted", "Without it the phone may pause the agent in the background and commands arrive late.", false),
        NOTIFICATION_LISTENER("Notification access", "Reads notifications from monitored apps for the safety scan (Phase 2.6).", false),
    }

    data class Row(val grant: Grant, val granted: Boolean)

    /** The rows in the order the parent should grant them (cheapest and most important first). */
    fun rows(granted: (Grant) -> Boolean): List<Row> = Grant.values().map { Row(it, granted(it)) }

    /** Grants still missing among the required ones; empty means pairing may be called complete. */
    fun missingRequired(rows: List<Row>): List<Grant> = rows.filter { it.grant.required && !it.granted }.map { it.grant }

    fun canComplete(rows: List<Row>): Boolean = missingRequired(rows).isEmpty()

    /** Short progress line for the header: "5 of 7 required grants done". */
    fun progressLine(rows: List<Row>): String {
        val req = rows.filter { it.grant.required }
        val done = req.count { it.granted }
        return "$done of ${req.size} required grants done" + if (done == req.size) " — protection is complete" else ""
    }

    /**
     * OEM hint for the grant, keyed on the manufacturer string (`Build.MANUFACTURER`, any case).
     * Samsung and Xiaomi are the two families that silently undo background work; the text tells the
     * parent where the hidden switch is. Null when there is nothing OEM-specific to say.
     */
    fun oemHint(grant: Grant, manufacturer: String?): String? {
        val m = manufacturer?.trim()?.lowercase() ?: return null
        return when {
            m.contains("samsung") -> when (grant) {
                Grant.BATTERY -> "Samsung: Settings › Battery › Background usage limits › Never sleeping apps → add OSRA; and turn off \"Put unused apps to sleep\"."
                Grant.ACCESSIBILITY -> "Samsung: Settings › Accessibility › Installed apps › OSRA › On. If it switches itself off, add OSRA to Never sleeping apps."
                else -> null
            }
            m.contains("xiaomi") || m.contains("redmi") || m.contains("poco") -> when (grant) {
                Grant.BATTERY -> "Xiaomi: Settings › Apps › Manage apps › OSRA › Autostart On, and Battery saver → No restrictions."
                Grant.OVERLAY -> "Xiaomi: Settings › Apps › Manage apps › OSRA › Other permissions › Display pop-up windows while running in the background → Allow."
                Grant.ACCESSIBILITY -> "Xiaomi: MIUI may turn the service off after a reboot unless Autostart is on for OSRA."
                else -> null
            }
            m.contains("huawei") || m.contains("honor") -> when (grant) {
                Grant.BATTERY -> "Huawei: Settings › Battery › App launch › OSRA → Manage manually, all three on."
                else -> null
            }
            m.contains("oppo") || m.contains("realme") || m.contains("oneplus") -> when (grant) {
                Grant.BATTERY -> "ColorOS: Settings › Battery › More settings › OSRA → Allow background activity; Auto-launch on."
                else -> null
            }
            else -> null
        }
    }

    /** Private DNS: Android's `private_dns_mode` is "off", "opportunistic" (Automatic) or "hostname" (a provider). */
    fun privateDnsOk(mode: String?): Boolean = mode == null || mode.trim().lowercase() != "hostname"
}
