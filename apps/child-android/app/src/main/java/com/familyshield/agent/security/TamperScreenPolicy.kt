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
enum class TamperScreen { NONE, DEACTIVATE_ADMIN, UNINSTALL, APP_INFO, PROTECTION_SETTINGS, SPECIAL_ACCESS, PRIVATE_DNS, SPACE_SETUP, VPN_CONSENT }

object TamperScreenPolicy {

    const val VPN_DIALOG_PACKAGE = "com.android.vpndialogs"

    // Android platform strings, VpnDialogs/res/values{,-ar}/strings.xml.
    private val VPN_CONSENT_TITLES = setOf("connection request", "طلب الاتصال")
    private val VPN_DISCONNECT_ACTIONS = setOf("disconnect", "قطع الاتصال")

    /** System packages that host the three screens (AOSP, Google and Samsung variants). */
    private val SYSTEM_PACKAGES = setOf(
        "com.android.settings",
        "com.android.packageinstaller",
        "com.google.android.packageinstaller",
        "com.samsung.android.packageinstaller",
        "com.miui.securitycenter",
        // osra-security#30: the Permission manager lives in its own package on Android 11 and later.
        "com.android.permissioncontroller",
        "com.google.android.permissioncontroller",
        "com.samsung.android.permissioncontroller",
    )

    // Secondary signal: the words on the screen, in every language the agent ships (English as before,
    // Arabic added for the first markets). Arabic entries are written unvowelled and with a bare alef,
    // because [normalize] folds the screen's text the same way. A fallback for OEM screens whose class
    // is not in [ADMIN_CLASSES] / [UNINSTALL_CLASSES] / [APP_INFO_CLASSES], never the only check.
    private val DEACTIVATE_VERBS = listOf(
        "deactivate", "turn off", "remove", "disable",
        "الغاء تنشيط", "الغاء التنشيط", "ايقاف", "ازالة", "تعطيل",
        // osra-security#5 (Flip4, One UI, ar-EG): the admin sheet's verb. Never bare «إلغاء», which is Cancel.
        "الغاء التفعيل", "الغاء تفعيل",
    )
    private val UNINSTALL_VERBS = listOf(
        "uninstall", "remove app", "delete app",
        "الغاء تثبيت", "الغاء التثبيت", "ازالة التثبيت", "ازالة تثبيت", "حذف التطبيق",
    )
    // The Flip4's force-stop button reads «إيقاف إجباري» and its dialog title «توقف إجباري».
    private val FORCE_STOP_VERBS = listOf("force stop", "فرض الايقاف", "فرض ايقاف", "ايقاف اجباري", "توقف اجباري")
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
    // The admin sheet serves activation AND deactivation under one class (AOSP `DeviceAdminAdd`, Samsung
    // `SecDeviceAdminAdd`, seen on the Flip4), so it counts only while our admin is active ([classify]).
    private val ADMIN_CLASSES = setOf("DeviceAdminAdd", "SecDeviceAdminAdd")
    // The admin LIST is never a protection screen; in Arabic its intro text carries «إلغاء تفعيل» and the list
    // names us, so the word path would misfire without this.
    private val NEVER_CLASSES = setOf(
        "DeviceAdminSettingsActivity",
        // Review of osra-security#29/#30: the list of every installed service and the runtime permission dialog.
        // Gating the list would block access to assistive tools (ADR-0021), and the runtime prompt is what a
        // parent answers while setting the phone up — a gate there would block onboarding itself.
        "SecAccessibilityInstalledAppsActivity",
        "AccessibilitySettingsActivity",
        "GrantPermissionsActivity",
    )
    private val UNINSTALL_CLASSES = setOf("UninstallerActivity")
    private val APP_INFO_CLASSES = setOf("InstalledAppDetails", "InstalledAppDetailsTop", "AppInfoDashboardActivity")

    /**
     * osra-security#29, Part 2 (Antigravity's scope, agreed on #813): the *other* system surfaces that decide what
     * the agent may do — drawing over other apps, reading usage, reading notifications, and the VPN entry. Each is a
     * page that names us and carries one of these phrases.
     *
     * Antigravity's Flip4 pass at `e131c080` found that words alone are not enough: the lists have a **Search apps**
     * bar, and while it is open the toolbar title is replaced by "Search apps", so the one phrase that identified the
     * page is gone and the child can toggle us off with no PIN. The five list pages do have their own top-level
     * `Settings$*` activity classes (One UI 8.0 and AOSP), so [SPECIAL_ACCESS_CLASSES] identifies them
     * language-independently and whatever the toolbar says. The VPN gear page is `SubSettings` and split-screen
     * passes a null class, so the words still carry those.
     */
    enum class SpecialAccess { OVERLAY, USAGE, NOTIFICATIONS, VPN }

    /**
     * The five pages whose activity class names the access, from the Flip4 pass (One UI 8.0, SDK 36) and AOSP. A class
     * match is language-independent and survives the Search bar, which is exactly what the words could not do.
     */
    private val SPECIAL_ACCESS_CLASSES: Map<String, SpecialAccess> = mapOf(
        "OverlaySettingsActivity" to SpecialAccess.OVERLAY,
        "UsageAccessSettingsActivity" to SpecialAccess.USAGE,
        "AppUsageAccessSettingsActivity" to SpecialAccess.USAGE,
        "NotificationAccessSettingsActivity" to SpecialAccess.NOTIFICATIONS,
        "NotificationAccessDetailsActivity" to SpecialAccess.NOTIFICATIONS,
    )

    private val SPECIAL_ACCESS_WORDS: Map<SpecialAccess, List<String>> = mapOf(
        // Arabic here is Google's own, taken from platform/packages/apps/Settings `values-ar` on the branches
        // android12-release to android16-release, plus the One UI 8.0 strings from Antigravity's Flip4 dump of
        // 15 Nov (quoted from the raw `uiautomator` XML), all folded with `normalize()`. A phrase that could not be
        // sourced from either was **removed** rather than guessed: five invented ones went wrong exactly that way.
        SpecialAccess.OVERLAY to listOf(
            "display over other apps", "draw over other apps", "appear on top",
            // Flip4 (One UI 8.0): the Search Apps results' function description, which is what the row says while the
            // page title is replaced by "Search apps"
            "show things on top of other apps",
            // 12–15 title, the switch on 12–16 (the shorter form also covers the longer one), 16 title
            "اظهار فوق التطبيقات الاخرى",
            "بظهور التطبيق فوق التطبيقات الاخرى",
            "الظهور فوق التطبيقات الاخرى",
            // One UI 8.0 in ar-AE: its own title and the row's function description, quoted from the raw dump
            "الظهور في الاعلى",
            "عرض المحتويات فوق تطبيقات اخرى",
        ),
        SpecialAccess.USAGE to listOf(
            "usage access", "usage data access",
            // 16 renamed the page and its switch. The switch's own label is "Permit access to app usage data", which
            // contains this phrase, so it is not listed twice: a duplicate entry here would make its test row pass
            // even after the entry it claims to cover was removed. `every new English phrase is guarded` feeds the
            // longer label and shows it is matched by the shorter phrase.
            "app usage data",
            // Flip4 (One UI 8.0): the Search Apps results' function description
            "monitor which other apps you use",
            // 12–15 title, and the 16 title and switch
            "الوصول الى بيانات الاستخدام",
            "الوصول الى بيانات استخدام التطبيق",
            // One UI 8.0 in ar-AE: its title drops «إلى», and the row's function description
            "وصول بيانات الاستخدام",
            "بمراقبة التطبيقات الاخرى التي تستخدمها",
        ),
        SpecialAccess.NOTIFICATIONS to listOf(
            // 12–16 switch (Arabic Language Bureau, review of #817); folded
            "الوصول الى الاشعارات",
            "notification access",
            // 12–14 title carries an ampersand, 15 renamed it
            "device & app notifications", "notification read, reply & control",
        ),
        SpecialAccess.VPN to listOf(
            // Review of osra-security#29: bare "vpn" matched any Settings page where a third-party VPN app
            // scrolled into view, so only the management actions count, and each phrase names one.
            "always-on vpn", "forget vpn", "delete vpn", "vpn profile", "disconnect vpn",
            // The per-version management phrases, quoted verbatim from Google's `values-ar` (12 to 16) by the Arabic
            // Language Bureau and folded with `normalize()` — which is why "VPN" reads "vpn" and the tanween is gone.
            // Always-on (12, 13, 14–16, and the short form), forget (12–14, 15–16), profile (12–14, 15–16), and
            // stay-connected (all). Two keep the closing bracket the quoted string carries.
            "شبكة vpn قيد التشغيل دائما",
            "vpn) قيد التشغيل دائما",
            "vpn) دائمة التفعيل",
            "نسيان شبكة vpn",
            "نسيان الشبكة الافتراضية الخاصة",
            "ملف شبكة vpn",
            "ملف الشبكة الافتراضية الخاصة",
            "متابعة الاتصال بشبكة vpn في جميع الاوقات",
            // Flip4 (One UI 8.0): the gear page is `SubSettings`, so it is matched by words. Its English switch and
            // its ar-AE switch and delete row, quoted from the raw dump
            "block connections without vpn",
            "تشغيل vpn دائما",
            "حظر الاتصالات من دون vpn",
            "حذف ملف تعريف vpn",
        ),
    )

    /** The permission *management* pages. Never the runtime prompt — see NEVER_CLASSES. */
    private val PERMISSION_MANAGEMENT_CLASSES = setOf(
        "ManagePermissionsActivity",
        "AppPermissionsActivity",
        "PermissionDetailsActivity",
    )

    /**
     * osra-security#29 and osra-security#30: the pages that change the agent's own permissions are protection
     * screens too. They do not read as "app info" — one carries a switch, the other per-permission rows — and
     * without them the permission can be changed with no PIN, which is the same loss of protection by another
     * route. Guarded only when the screen names the agent, like every other class here: the same pages exist for
     * every app on the phone. The reproduction and the exact navigation stay in the private reports.
     */
    private val PROTECTION_SETTINGS_CLASSES = setOf(
        // Our service's accessibility detail page: AOSP, Google and Samsung wording of the same page.
        "AccessibilityDetails",
        "AccessibilityServiceDetails",
        "SecAccessibilityDetailsActivity",
    )

    /**
     * osra-security#6 item 3: the screens that create a second space on the phone — Samsung Dual Messenger's
     * app list (which clones an app into the clone profile) and Secure Folder's setup. Package **and** class,
     * both from the Flip4 capture (`topResumedActivity`, One UI, SDK 36). They never name the agent, so this
     * is the one place the class alone decides; the package pins it to the one system app that hosts it.
     */
    private val SPACE_SETUP_SCREENS = setOf(
        "com.samsung.android.da.daagent" to "DualAppActivity",
        "com.samsung.knox.securefolder" to "WelcomeActivity",
    )

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
                // Arabic Language Bureau, review of #817: direction marks are formatting, not text. Google's Arabic
                // strings that carry a Latin word begin with U+200F, and a mark inside a phrase would break
                // `contains`. Dropping the Cf marks removes the risk rather than relying on where they sit.
                '\u061C', '\u200E', '\u200F', in '\u202A'..'\u202E', in '\u2066'..'\u2069' -> Unit
                '\u0623', '\u0625', '\u0622' -> out.append('\u0627')
                '\u0624' -> out.append('\u0648')
                else -> out.append(ch)
            }
        }
        return out.toString()
    }

    /**
     * osra-security#7: whether a window of [packageName] can be a protection screen at all, so the guard's cover
     * reads the texts of only those windows.
     */
    fun mayHostProtectionScreen(packageName: String?): Boolean =
        packageName != null && (packageName in SYSTEM_PACKAGES || packageName == VPN_DIALOG_PACKAGE || SPACE_SETUP_SCREENS.any { it.first == packageName })

    /**
     * Classifies a foreground window. [packageName] is the window's package; [texts] every visible
     * text/content-description on it, in any order; [agentLabel] the agent's launcher label
     * ("OSRA Child Agent"), [adminLabel] the device-admin label ("OSRA parental controls") and
     * [agentPackage] its package name — any of them naming the agent on the screen. [windowClass] is the
     * class of the window's last TYPE_WINDOW_STATE_CHANGED event, when it is known. [ourAdminActive] is whether
     * the agent's device admin is active right now: the admin sheet is a deactivation only then. While it is
     * inactive the same sheet is the activation the parent runs in setup, and it is never guarded.
     *
     * A screen still has to name the agent to count, whichever signal matched: the class alone would put
     * the guard in front of every app's admin sheet and every uninstall. The one exception is
     * [TamperScreen.SPACE_SETUP] (osra-security#6): creating a second space is a protection change whatever
     * app it is for, and the screen never names us.
     */
    fun classify(
        packageName: String?,
        texts: List<CharSequence?>,
        agentLabel: String,
        adminLabel: String,
        agentPackage: String,
        ourAdminActive: Boolean,
        windowClass: String? = null,
        /**
         * Fable's B2 on #813: the accessibility page shows **our own description text**, in the phone's
         * language, and no other app's does. It is the one signal that does not depend on a class name — which
         * matters because current Settings builds often host that page in a generic fragment host, and the
         * window event then carries the host's class.
         */
        agentServiceDescription: String = "",
        /** Whether the agent holds a location grant right now; the permission page is only ours to protect then. */
        ourLocationActive: Boolean = false,
        /**
         * Part 2 of osra-security#29: which special accesses we hold **right now**. A page for one we do not hold is
         * the parent granting it (onboarding does exactly that), so it is never a protection screen — the same shape
         * as [ourAdminActive] and [ourLocationActive].
         */
        ourSpecialAccess: Set<SpecialAccess> = emptySet(),
        filterProtectionActive: Boolean = false,
        ownVpnConsentPending: Boolean = false,
    ): TamperScreen {
        if (packageName == VPN_DIALOG_PACKAGE) {
            if (!filterProtectionActive) return TamperScreen.NONE
            val dialogText = texts.filterNotNull().map { normalize(it.toString()) }
            val label = normalize(agentLabel)
            val mentionsAgent = label.isNotEmpty() && dialogText.any { it.contains(label) }
            val managesFilter = simpleName(windowClass) == "ManageDialog" && mentionsAgent
            val requestsConsent = simpleName(windowClass) == "ConfirmDialog" ||
                dialogText.any { it in VPN_CONSENT_TITLES }
            return when {
                managesFilter && dialogText.any { it in VPN_DISCONNECT_ACTIONS } -> TamperScreen.VPN_CONSENT
                requestsConsent && !(ownVpnConsentPending && (dialogText.isEmpty() || mentionsAgent)) ->
                    TamperScreen.VPN_CONSENT
                else -> TamperScreen.NONE
            }
        }
        if (packageName != null && (packageName to simpleName(windowClass)) in SPACE_SETUP_SCREENS) {
            return TamperScreen.SPACE_SETUP
        }
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

        // Antigravity's R1 on #813: NEVER_CLASSES is checked here, before every protection rule below, so the
        // accessibility list, the settings hub and the runtime prompt cannot be caught by the description text or
        // by the permission-management branch further down.
        if (simpleName(windowClass) in NEVER_CLASSES) return TamperScreen.NONE


        // Fable's B2 on #813: our own accessibility description is proof that this is *our* service page, whatever
        // the host activity is called, and it is a Settings screen by then.
        if (packageName == "com.android.settings") {
            val description = normalize(agentServiceDescription).takeIf { it.length >= 24 }
            if (description != null && joinedAll.contains(description)) return TamperScreen.PROTECTION_SETTINGS
        }
        // Fable's B2, second half, corrected by Antigravity's B2: PermissionController also hosts the runtime
        // permission prompt, and the management pages are opened by onboarding itself when the parent grants
        // background location. So this is **not** the whole package — it is the management classes, and the
        // runtime dialog is never a screen (NEVER_CLASSES).
        if (packageName.contains("permissioncontroller") && simpleName(windowClass) in PERMISSION_MANAGEMENT_CLASSES) {
            // Antigravity's R2 on #813: onboarding opens this very page to grant background location, after the
            // parent has set the PIN. With no location grant yet there is nothing to protect, and gating it blocks
            // the parent's own setup; the same shape as ADMIN_CLASSES above, which only counts while our admin is on.
            return if (ourLocationActive) TamperScreen.PROTECTION_SETTINGS else TamperScreen.NONE
        }

        when (simpleName(windowClass)) {
            in NEVER_CLASSES -> return TamperScreen.NONE
            in ADMIN_CLASSES -> return if (ourAdminActive) TamperScreen.DEACTIVATE_ADMIN else TamperScreen.NONE
            in UNINSTALL_CLASSES -> return TamperScreen.UNINSTALL
            in APP_INFO_CLASSES -> return TamperScreen.APP_INFO
            in PROTECTION_SETTINGS_CLASSES -> return TamperScreen.PROTECTION_SETTINGS
        }

        // Part 2 runs **after** the class match (Antigravity's item 4): OSRA's App Info screen carries a "Display over
        // other apps" summary row, so a word-first check reclassified it from APP_INFO to SPECIAL_ACCESS. A screen
        // identified by its class keeps that identity; only the fragment-hosted pages fall through to here.
        if (packageName == "com.android.settings") {
            // Antigravity's Flip4 pass: the access pages themselves are identified by class, so the Search bar (which
            // replaces the page title) cannot hide them. Held → protected; not held → this is the parent granting it.
            val byClass = simpleName(windowClass)?.let { SPECIAL_ACCESS_CLASSES[it] }
            if (byClass != null) return if (byClass in ourSpecialAccess) TamperScreen.SPECIAL_ACCESS else TamperScreen.NONE
            val holds = SPECIAL_ACCESS_WORDS.filterKeys { it in ourSpecialAccess }
            if (holds.any { (_, words) -> words.any { joinedAll.contains(normalize(it)) } }) {
                return TamperScreen.SPECIAL_ACCESS
            }
        }

        val joined = joinedAll
        fun anyOf(words: List<String>) = words.any { joined.contains(normalize(it)) }
        val mentionsAdmin = anyOf(ADMIN_WORDS)
        return when {
            // Nothing to deactivate while our admin is inactive: an activation sheet that says "disable" in its
            // list of powers is not a tamper screen.
            mentionsAdmin && anyOf(DEACTIVATE_VERBS) -> if (ourAdminActive) TamperScreen.DEACTIVATE_ADMIN else TamperScreen.NONE
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
