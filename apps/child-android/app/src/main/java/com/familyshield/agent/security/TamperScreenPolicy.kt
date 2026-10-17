package com.familyshield.agent.security

/**
 * Pure classifier for the OS screens a child uses to strip the agent's protection (ADR-0010 §3):
 * the Settings "deactivate device admin" confirmation, the package installer's uninstall dialog and
 * the App-info page (force stop / uninstall / clear data) for OUR package. Free of Android types so
 * the decision table is unit-tested on the JVM; [com.familyshield.agent.services.AccessibilityMonitorService]
 * feeds it the foreground package and the visible texts.
 *
 * Matching is deliberately conservative: a screen counts only when it is in a system package AND the
 * agent is named on it (label or package name) AND a removal verb is visible. A Settings page that
 * merely lists apps, or the admin list without our row expanded, is not a tamper screen.
 */
enum class TamperScreen { NONE, DEACTIVATE_ADMIN, UNINSTALL, APP_INFO }

object TamperScreenPolicy {

    /** System packages that host the three screens (AOSP, Google and Samsung variants). */
    private val SYSTEM_PACKAGES = setOf(
        "com.android.settings",
        "com.android.packageinstaller",
        "com.google.android.packageinstaller",
        "com.samsung.android.packageinstaller",
        "com.miui.securitycenter",
    )

    private val DEACTIVATE_VERBS = listOf("deactivate", "turn off", "remove", "disable")
    private val UNINSTALL_VERBS = listOf("uninstall", "remove app", "delete app")
    private val APP_INFO_VERBS = listOf("force stop", "force close", "clear data", "clear storage", "uninstall")
    private val ADMIN_WORDS = listOf("device admin", "device administrator", "admin app", "device management")

    /**
     * Classifies a foreground window. [packageName] is the window's package; [texts] every visible
     * text/content-description on it, in any order; [agentLabel] the agent's launcher label
     * ("OSRA Child Agent"), [adminLabel] the device-admin label ("OSRA parental controls") and
     * [agentPackage] its package name — any of them naming the agent on the screen.
     */
    fun classify(
        packageName: String?,
        texts: List<CharSequence?>,
        agentLabel: String,
        adminLabel: String,
        agentPackage: String,
    ): TamperScreen {
        if (packageName == null || packageName !in SYSTEM_PACKAGES) return TamperScreen.NONE
        val lower = texts.filterNotNull().map { it.toString().lowercase() }
        if (lower.isEmpty()) return TamperScreen.NONE
        val namesUs = lower.any { t ->
            t.contains(agentLabel.lowercase()) || t.contains(adminLabel.lowercase()) || t.contains(agentPackage.lowercase())
        }
        if (!namesUs) return TamperScreen.NONE
        val joined = lower.joinToString(" | ")
        val mentionsAdmin = ADMIN_WORDS.any { joined.contains(it) }
        return when {
            mentionsAdmin && DEACTIVATE_VERBS.any { joined.contains(it) } -> TamperScreen.DEACTIVATE_ADMIN
            UNINSTALL_VERBS.any { joined.contains(it) } && !joined.contains("force stop") -> TamperScreen.UNINSTALL
            APP_INFO_VERBS.any { joined.contains(it) } -> TamperScreen.APP_INFO
            else -> TamperScreen.NONE
        }
    }

    /**
     * Whether the guard should step in for [screen]. It never intervenes inside a parent-granted
     * grace window (the parent just entered the PIN, [graceUntilMs] in the future) and never when no
     * PIN exists yet — before a PIN is set there is nothing to verify against and locking a family out
     * of Settings would be worse than the tamper.
     */
    fun shouldGuard(screen: TamperScreen, pinConfigured: Boolean, graceUntilMs: Long, nowMs: Long): Boolean =
        screen != TamperScreen.NONE && pinConfigured && nowMs >= graceUntilMs

    /** Length of the window during which a verified PIN lets the parent finish what they opened. */
    const val GRACE_MS: Long = 2 * 60 * 1000
}
