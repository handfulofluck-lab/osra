package com.familyshield.agent.security

/**
 * Pure classifier for the OS screens a child uses to strip the agent's protection (ADR-0010 §3):
 * the Settings "deactivate device admin" confirmation, the package installer's uninstall dialog and
 * the App-info page (force stop / uninstall / clear data) for OUR package. Free of Android types so
 * the decision table is unit-tested on the JVM; [com.familyshield.agent.services.AccessibilityMonitorService]
 * feeds it the foreground package and the visible texts.
 *
 * Matching is deliberately conservative: a screen counts only when it is in a system package AND the
 * agent is named on it (label or package name) AND it is a protection screen. That last part is read
 * from the window's class first, which does not depend on the phone's language, and from a removal
 * verb in English or Arabic second. A Settings page that merely lists apps, or the admin list without
 * our row expanded, is not a tamper screen.
 */
enum class TamperScreen { NONE, DEACTIVATE_ADMIN, UNINSTALL, APP_INFO, PRIVATE_DNS }

object TamperScreenPolicy {

    /** System packages that host the three screens (AOSP, Google and Samsung variants). */
    private val SYSTEM_PACKAGES = setOf(
        "com.android.settings",
        "com.android.packageinstaller",
        "com.google.android.packageinstaller",
        "com.samsung.android.packageinstaller",
        "com.miui.securitycenter",
    )

    // Secondary signal: the words on the screen, in every language the agent ships (English as before,
    // Arabic added for the first markets). Arabic entries are written unvowelled and with a bare alef,
    // because [normalize] folds the screen's text the same way. A fallback for OEM screens whose class
    // is not in [ADMIN_CLASSES] / [UNINSTALL_CLASSES] / [APP_INFO_CLASSES], never the only check.
    private val DEACTIVATE_VERBS = listOf(
        "deactivate", "turn off", "remove", "disable",
        "الغاء تنشيط", "الغاء التنشيط", "ايقاف", "ازالة", "تعطيل",
    )
    private val UNINSTALL_VERBS = listOf(
        "uninstall", "remove app", "delete app",
        "الغاء تثبيت", "الغاء التثبيت", "ازالة التثبيت", "ازالة تثبيت", "حذف التطبيق",
    )
    private val FORCE_STOP_VERBS = listOf("force stop", "فرض الايقاف", "فرض ايقاف", "ايقاف اجباري")
    private val APP_INFO_VERBS = FORCE_STOP_VERBS + listOf(
        "force close", "clear data", "clear storage", "uninstall",
        "محو البيانات", "مسح البيانات", "محو مساحة التخزين", "مسح مساحة التخزين", "الغاء التثبيت", "الغاء تثبيت",
    )
    private val ADMIN_WORDS = listOf(
        "device admin", "device administrator", "admin app", "device management",
        "مشرف الجهاز", "مسوول الجهاز", "مسؤول الجهاز", "ادارة الجهاز",
    )
    /** Plan 1.6/1.4: the Private DNS dialog — a named provider bypasses the DNS sinkhole, so it is a protection screen too. */
    private val PRIVATE_DNS_WORDS = listOf(
        "private dns provider hostname", "private dns",
        "نظام اسماء النطاقات الخاص", "dns خاص", "dns الخاص",
    )
    private val PRIVATE_DNS_FIELDS = listOf("hostname", "provider", "dns.google", "cloudflare-dns", "اسم المضيف", "مزود")

    // Primary signal: what the window IS, not what it says (osra-security#5). The class of the
    // TYPE_WINDOW_STATE_CHANGED event, matched on its simple name so the AOSP, Google and OEM packages
    // of the same activity all match. These do not depend on the phone's language.
    private val ADMIN_CLASSES = setOf("DeviceAdminAdd")
    private val UNINSTALL_CLASSES = setOf("UninstallerActivity")
    private val APP_INFO_CLASSES = setOf("InstalledAppDetails", "InstalledAppDetailsTop", "AppInfoDashboardActivity")

    /** The simple name of a window class (`com.android.settings.DeviceAdminAdd` → `DeviceAdminAdd`, `Settings$X` → `X`). */
    private fun simpleName(windowClass: String?): String? =
        windowClass?.substringAfterLast('.')?.substringAfterLast('$')?.takeIf { it.isNotEmpty() }

    /**
     * Folds text so one word list matches what different screens render: lowercase for Latin, and for
     * Arabic drops the short vowels, shadda and tatweel and writes every alef-with-hamza and the
     * hamza-on-waw as the bare letter. Applied to the screen and the lists alike.
     */
    internal fun normalize(s: String): String {
        val out = StringBuilder(s.length)
        for (ch in s.lowercase()) {
            when (ch) {
                in '\u064B'..'\u0652', '\u0640' -> Unit
                '\u0623', '\u0625', '\u0622' -> out.append('\u0627')
                '\u0624' -> out.append('\u0648')
                else -> out.append(ch)
            }
        }
        return out.toString()
    }

    /**
     * Classifies a foreground window. [packageName] is the window's package; [texts] every visible
     * text/content-description on it, in any order; [agentLabel] the agent's launcher label
     * ("OSRA Child Agent"), [adminLabel] the device-admin label ("OSRA parental controls") and
     * [agentPackage] its package name — any of them naming the agent on the screen. [windowClass] is the
     * class of the window's last TYPE_WINDOW_STATE_CHANGED event, when it is known.
     *
     * A screen still has to name the agent to count, whichever signal matched: the class alone would put
     * the guard in front of every app's admin sheet and every uninstall.
     */
    fun classify(
        packageName: String?,
        texts: List<CharSequence?>,
        agentLabel: String,
        adminLabel: String,
        agentPackage: String,
        windowClass: String? = null,
    ): TamperScreen {
        if (packageName == null || packageName !in SYSTEM_PACKAGES) return TamperScreen.NONE
        val lower = texts.filterNotNull().map { normalize(it.toString()) }
        if (lower.isEmpty()) return TamperScreen.NONE
        val joinedAll = lower.joinToString(" | ")
        if (packageName == "com.android.settings") {
            if (PRIVATE_DNS_WORDS.any { joinedAll.contains(normalize(it)) } &&
                PRIVATE_DNS_FIELDS.any { joinedAll.contains(normalize(it)) }
            ) return TamperScreen.PRIVATE_DNS
        }
        val names = listOf(agentLabel, adminLabel, agentPackage).map { normalize(it) }.filter { it.isNotEmpty() }
        val namesUs = lower.any { t -> names.any { t.contains(it) } }
        if (!namesUs) return TamperScreen.NONE

        when (simpleName(windowClass)) {
            in ADMIN_CLASSES -> return TamperScreen.DEACTIVATE_ADMIN
            in UNINSTALL_CLASSES -> return TamperScreen.UNINSTALL
            in APP_INFO_CLASSES -> return TamperScreen.APP_INFO
        }

        val joined = joinedAll
        fun anyOf(words: List<String>) = words.any { joined.contains(normalize(it)) }
        val mentionsAdmin = anyOf(ADMIN_WORDS)
        return when {
            mentionsAdmin && anyOf(DEACTIVATE_VERBS) -> TamperScreen.DEACTIVATE_ADMIN
            anyOf(UNINSTALL_VERBS) && !anyOf(FORCE_STOP_VERBS) -> TamperScreen.UNINSTALL
            anyOf(APP_INFO_VERBS) -> TamperScreen.APP_INFO
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
