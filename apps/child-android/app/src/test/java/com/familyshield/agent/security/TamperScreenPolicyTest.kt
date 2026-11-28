package com.familyshield.agent.security

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/** ADR-0010 §3: which OS screens the guard steps in front of, and when it must stand down. */
class TamperScreenPolicyTest {
    private val agent = "OSRA"
    private val admin = "OSRA parental controls"
    private val pkg = "com.familyshield.agent"

    private fun classify(packageName: String?, vararg texts: String) =
        TamperScreenPolicy.classify(packageName, texts.toList(), agent, admin, pkg, ourAdminActive = true)

    @Test
    fun `the deactivate-admin confirmation for our admin is DEACTIVATE_ADMIN`() {
        assertEquals(
            TamperScreen.DEACTIVATE_ADMIN,
            classify("com.android.settings", "Device admin apps", "OSRA parental controls", "Deactivate this device admin app", "Cancel"),
        )
        // Samsung wording
        assertEquals(
            TamperScreen.DEACTIVATE_ADMIN,
            classify("com.android.settings", "Device admin app", "OSRA parental controls", "Lets OSRA lock the device", "Deactivate"),
        )
    }

    @Test
    fun `the package installer's uninstall dialog for our app is UNINSTALL`() {
        assertEquals(TamperScreen.UNINSTALL, classify("com.google.android.packageinstaller", "OSRA", "Do you want to uninstall this app?", "Cancel", "OK"))
        assertEquals(TamperScreen.UNINSTALL, classify("com.samsung.android.packageinstaller", "Uninstall OSRA?", "Cancel", "Uninstall"))
    }

    @Test
    fun `app info for our package is APP_INFO`() {
        assertEquals(TamperScreen.APP_INFO, classify("com.android.settings", "App info", "OSRA", "Force stop", "Storage", "Permissions"))
        assertEquals(TamperScreen.APP_INFO, classify("com.android.settings", "OSRA", "com.familyshield.agent", "Clear data", "Clear cache"))
        // osra-security#78: Xiaomi/MIUI App-info class (ApplicationsDetailsActivity) is matched by class,
        // language-independently, even when no English/Arabic removal verb has scrolled into view yet.
        assertEquals(
            TamperScreen.APP_INFO,
            TamperScreenPolicy.classify(
                "com.miui.securitycenter",
                listOf<CharSequence>("OSRA", "Stockage", "Autorisations", "Notifications"),
                agent, admin, pkg,
                ourAdminActive = true,
                windowClass = "com.miui.appmanager.ApplicationsDetailsActivity",
            ),
        )
        assertEquals(
            "another app's MIUI ApplicationsDetailsActivity stays NONE",
            TamperScreen.NONE,
            TamperScreenPolicy.classify(
                "com.miui.securitycenter",
                listOf<CharSequence>("YouTube", "Stockage", "Autorisations"),
                agent, admin, pkg,
                ourAdminActive = true,
                windowClass = "com.miui.appmanager.ApplicationsDetailsActivity",
            ),
        )
        // MIUI AppManagerMainActivity: plain app list is NONE; selected OSRA action bar with verb is guarded.
        assertEquals(
            TamperScreen.NONE,
            TamperScreenPolicy.classify(
                "com.miui.securitycenter",
                listOf<CharSequence>("Manage apps", "OSRA", "YouTube"),
                agent, admin, pkg,
                ourAdminActive = true,
                windowClass = "com.miui.appmanager.AppManagerMainActivity",
            ),
        )
        assertEquals(
            TamperScreen.UNINSTALL,
            TamperScreenPolicy.classify(
                "com.miui.securitycenter",
                listOf<CharSequence>("OSRA", "Uninstall", "Clear data"),
                agent, admin, pkg,
                ourAdminActive = true,
                windowClass = "com.miui.appmanager.AppManagerMainActivity",
            ),
        )
        // MIUI package installers
        for (miuiInstaller in listOf("com.miui.packageinstaller", "com.miui.globalpackageinstaller")) {
            assertEquals(
                miuiInstaller,
                TamperScreen.UNINSTALL,
                TamperScreenPolicy.classify(
                    miuiInstaller,
                    listOf<CharSequence>("OSRA", "Annuler", "OK"),
                    agent, admin, pkg,
                    ourAdminActive = true,
                    windowClass = "com.android.packageinstaller.UninstallerActivity",
                ),
            )
        }
    }

    /**
     * osra-security#29 (AS02 on the Flip4): the accessibility service could be switched off with no PIN and
     * blocking stopped at once. The page is a switch and says nothing about uninstalling, so no word path reached
     * it — and until this row it was classified NONE.
     */
    @Test
    fun `our accessibility detail page is a protection screen`() {
        for (cls in listOf(
            "com.android.settings.accessibility.AccessibilityDetails",
            "com.android.settings.accessibility.AccessibilityServiceDetails",
            "com.samsung.android.settings.accessibility.SecAccessibilityDetailsActivity",
        )) {
            assertEquals(
                cls,
                TamperScreen.PROTECTION_SETTINGS,
                classifyWindow("com.android.settings", cls, "OSRA accessibility", "Allowed", "Use OSRA to observe what is on screen"),
            )
        }
    }

    /**
     * osra-security#30: the location grant is a protection the parent gave; switching it off stops live location
     * and geofence alerts, with no PIN, from its own package.
     */
    @Test
    fun `our permissions page is a protection screen`() {
        for (pkg in listOf("com.android.permissioncontroller", "com.google.android.permissioncontroller")) {
            for (cls in listOf("ManagePermissionsActivity", "AppPermissionsActivity", "PermissionDetailsActivity")) {
                assertEquals(
                    "$pkg/$cls",
                    TamperScreen.PROTECTION_SETTINGS,
                    TamperScreenPolicy.classify(
                        pkg,
                        listOf<CharSequence>("OSRA", "Location", "Don't allow", "Allow all the time"),
                        agent, admin, pkg,
                        ourAdminActive = true,
                        windowClass = cls,
                        // R2: the page is ours to protect only while we hold the grant it manages.
                        ourLocationActive = true,
                    ),
                )
            }
        }
    }

    /** The same two pages exist for every app on the phone; only ours is a protection screen. */
    @Test
    fun `another app's accessibility and permission pages stay NONE`() {
        assertEquals(
            TamperScreen.NONE,
            classifyWindow(
                "com.android.settings",
                "com.android.settings.accessibility.AccessibilityDetails",
                "Chrome accessibility", "Allowed", "Use Chrome to observe what is on screen",
            ),
        )
        assertEquals(
            TamperScreen.NONE,
            classifyWindow("com.android.permissioncontroller", "Camera", "Photos", "Don't allow"),
        )
    }

    /**
     * Fable's B1 on #813: the rows above feed in the class names the code lists, so they pass by construction —
     * and on current Settings builds the accessibility page is often a fragment in a generic host, whose class
     * matches nothing. These rows are the non-tautological half: an **unknown** class and **our description
     * text** is still guarded, which is what survives an OEM rename or a fragment host.
     */
    @Test
    fun `our accessibility description is guarded whatever the window class is`() {
        val description = "OSRA monitors app usage to enforce your parent's screen-time rules."
        for (cls in listOf(null, "Settings", "com.android.settings.MainSettings", "com.android.settings.SubSettings")) {
            assertEquals(
                "class=$cls",
                TamperScreen.PROTECTION_SETTINGS,
                TamperScreenPolicy.classify(
                    "com.android.settings",
                    listOf<CharSequence>("OSRA accessibility", "Allowed", description),
                    agent, admin, pkg,
                    ourAdminActive = true,
                    windowClass = cls,
                    agentServiceDescription = description,
                ),
            )
        }
        // Another app's page carries none of it.
        assertEquals(
            TamperScreen.NONE,
            TamperScreenPolicy.classify(
                "com.android.settings",
                listOf<CharSequence>("Chrome accessibility", "Allowed", "Use Chrome to observe what is on screen"),
                agent, admin, pkg,
                ourAdminActive = true,
                windowClass = "Settings",
                agentServiceDescription = description,
            ),
        )
    }

    /**
     * osra-security#30 review (Antigravity B2): PermissionController hosts both the management pages **and** the
     * runtime permission dialog, and onboarding opens the management page itself when the parent grants background
     * location. So the package alone is not enough: the management classes are guarded, the runtime prompt is
     * never a screen, and neither is the all-services accessibility list (gating it would block TalkBack).
     */
    /**
     * Antigravity's R2: onboarding opens this very page to grant background location, after the PIN is set. With no
     * grant yet there is nothing to protect, and gating it would block the parent's own setup.
     */
    @Test
    fun `the permission page is only guarded while we hold a location grant`() {
        fun classifyWithGrant(granted: Boolean) = TamperScreenPolicy.classify(
            "com.android.permissioncontroller",
            listOf<CharSequence>("OSRA", "Location", "Allow all the time"),
            agent, admin, pkg,
            ourAdminActive = true,
            windowClass = "ManagePermissionsActivity",
            ourLocationActive = granted,
        )
        assertEquals("nothing to protect yet", TamperScreen.NONE, classifyWithGrant(false))
        assertEquals("the grant is ours to protect", TamperScreen.PROTECTION_SETTINGS, classifyWithGrant(true))
    }

    /** Antigravity's R1: the never-list wins over the description text, not after it. */
    @Test
    fun `the list stays NONE even when the description is on screen`() {
        assertEquals(
            TamperScreen.NONE,
            TamperScreenPolicy.classify(
                "com.android.settings",
                listOf<CharSequence>("Installed apps", "OSRA", "OSRA monitors app usage to enforce your parent's screen-time rules."),
                agent, admin, pkg,
                ourAdminActive = true,
                windowClass = "SecAccessibilityInstalledAppsActivity",
                agentServiceDescription = "OSRA monitors app usage to enforce your parent's screen-time rules.",
            ),
        )
    }

    @Test
    fun `the permission management pages are guarded, the runtime prompt and the lists are not`() {
        assertEquals(
            TamperScreen.PROTECTION_SETTINGS,
            TamperScreenPolicy.classify(
                "com.samsung.android.permissioncontroller",
                listOf<CharSequence>("OSRA", "Location", "Don't allow"),
                agent, admin, pkg, ourAdminActive = true,
                windowClass = "ManagePermissionsActivity", ourLocationActive = true,
            ),
        )
        assertEquals(
            TamperScreen.PROTECTION_SETTINGS,
            TamperScreenPolicy.classify(
                "com.android.permissioncontroller",
                listOf<CharSequence>("OSRA", "Camera", "Allow"),
                agent, admin, pkg, ourAdminActive = true,
                windowClass = "AppPermissionsActivity", ourLocationActive = true,
            ),
        )
        assertEquals(
            "the runtime prompt is not a protection screen",
            TamperScreen.NONE,
            classifyWindow("com.android.permissioncontroller", "GrantPermissionsActivity", "Allow OSRA to access this device's location?", "While using the app"),
        )
        assertEquals(
            "the accessibility list of every service is not a protection screen",
            TamperScreen.NONE,
            classifyWindow("com.android.settings", "SecAccessibilityInstalledAppsActivity", "Installed apps", "OSRA", "TalkBack"),
        )
        assertEquals(
            "and neither is the accessibility settings hub",
            TamperScreen.NONE,
            classifyWindow("com.android.settings", "AccessibilitySettingsActivity", "Accessibility", "OSRA", "TalkBack"),
        )
    }

    @Test
    fun `screens that do not name us, or are not system packages, are NONE`() {
        assertEquals(TamperScreen.NONE, classify("com.android.settings", "Device admin apps", "Find My Device", "Deactivate"))
        assertEquals(TamperScreen.NONE, classify("com.android.settings", "App info", "YouTube", "Force stop", "Uninstall"))
        assertEquals(TamperScreen.NONE, classify("com.whatsapp", "OSRA", "Uninstall", "Deactivate device admin"))
        assertEquals(TamperScreen.NONE, classify(null, "OSRA", "Uninstall"))
        assertEquals(TamperScreen.NONE, classify("com.android.settings"))
        // The admin list with our row but no removal verb: just browsing.
        assertEquals(TamperScreen.NONE, classify("com.android.settings", "Device admin apps", "OSRA parental controls", "Find My Device"))
    }

    @Test
    fun `the guard stands down inside the grace window and before a pin exists`() {
        val now = 1_000_000L
        assertTrue(TamperScreenPolicy.shouldGuard(TamperScreen.UNINSTALL, pinConfigured = true, graceUntilMs = 0L, nowMs = now))
        assertFalse(TamperScreenPolicy.shouldGuard(TamperScreen.UNINSTALL, pinConfigured = true, graceUntilMs = now + 1, nowMs = now))
        assertFalse(TamperScreenPolicy.shouldGuard(TamperScreen.UNINSTALL, pinConfigured = false, graceUntilMs = 0L, nowMs = now))
        assertFalse(TamperScreenPolicy.shouldGuard(TamperScreen.NONE, pinConfigured = true, graceUntilMs = 0L, nowMs = now))
        assertTrue(TamperScreenPolicy.shouldGuard(TamperScreen.DEACTIVATE_ADMIN, pinConfigured = true, graceUntilMs = now, nowMs = now))
    }

    @Test
    fun `the Private DNS provider dialog is PRIVATE_DNS even though it does not name us`() {
        assertEquals(TamperScreen.PRIVATE_DNS, classify("com.android.settings", "Private DNS", "Off", "Automatic", "Private DNS provider hostname", "Save"))
        assertEquals(TamperScreen.PRIVATE_DNS, classify("com.android.settings", "Select Private DNS Mode", "Private DNS provider hostname", "dns.google"))
        // the Network settings list that merely mentions Private DNS as a row is not the dialog
        assertEquals(TamperScreen.NONE, classify("com.android.settings", "Connections", "Wi-Fi", "Private DNS", "Automatic"))
        // and only Settings hosts it
        assertEquals(TamperScreen.NONE, classify("com.android.chrome", "Private DNS provider hostname"))
    }

    // ---- osra-security#5: protection screens in a non-English system language ----
    // On an Arabic phone our labels resolve to Arabic too: the launcher label stays the brand ("OSRA"),
    // the device-admin label is the Arabic string from values-ar.
    private val adminAr = "الرقابة الأبوية من OSRA"

    /** The class matters for the rows below: these pages say nothing that a word list would catch. */
    private fun classifyWindow(packageName: String?, windowClass: String?, vararg texts: String) =
        TamperScreenPolicy.classify(packageName, texts.toList(), agent, admin, pkg, ourAdminActive = true, windowClass = windowClass)

    private fun classifyAr(packageName: String?, windowClass: String?, vararg texts: String) =
        TamperScreenPolicy.classify(packageName, texts.toList(), agent, adminAr, pkg, ourAdminActive = true, windowClass = windowClass)

    @Test
    fun `each protection class classifies with no verb on the screen, in Arabic or with only our name`() {
        // Arabic text that names us but carries none of the listed verbs.
        assertEquals(
            TamperScreen.DEACTIVATE_ADMIN,
            classifyAr("com.android.settings", "com.android.settings.DeviceAdminAdd", adminAr, "يتيح هذا التطبيق قفل الجهاز"),
        )
        assertEquals(
            TamperScreen.DEACTIVATE_ADMIN,
            classifyAr(
                "com.android.settings",
                "com.android.settings.applications.specialaccess.deviceadmin.DeviceAdminAdd",
                adminAr,
            ),
        )
        assertEquals(
            TamperScreen.UNINSTALL,
            classifyAr("com.google.android.packageinstaller", "com.android.packageinstaller.UninstallerActivity", "OSRA"),
        )
        assertEquals(
            TamperScreen.UNINSTALL,
            classifyAr("com.samsung.android.packageinstaller", "com.android.packageinstaller.UninstallerActivity", "OSRA", "؟"),
        )
        assertEquals(
            TamperScreen.APP_INFO,
            classifyAr("com.android.settings", "com.android.settings.applications.InstalledAppDetailsTop", "OSRA", "الأذونات"),
        )
        assertEquals(
            TamperScreen.APP_INFO,
            classifyAr("com.android.settings", "com.android.settings.Settings\$AppInfoDashboardActivity", "OSRA"),
        )
        // A language we ship no strings for: the admin label falls back to English, the class still matches.
        assertEquals(
            TamperScreen.DEACTIVATE_ADMIN,
            TamperScreenPolicy.classify(
                "com.android.settings",
                listOf("OSRA parental controls", "Désactiver cette application"),
                agent, admin, pkg,
                ourAdminActive = true,
                windowClass = "com.android.settings.DeviceAdminAdd",
            ),
        )
    }

    @Test
    fun `a protection class that does not name us stays NONE, so other apps' admin sheets are left alone`() {
        assertEquals(
            TamperScreen.NONE,
            classifyAr("com.android.settings", "com.android.settings.DeviceAdminAdd", "العثور على جهازي", "إلغاء تنشيط"),
        )
        assertEquals(
            TamperScreen.NONE,
            classifyAr("com.google.android.packageinstaller", "com.android.packageinstaller.UninstallerActivity", "يوتيوب", "إلغاء التثبيت"),
        )
        assertEquals(
            TamperScreen.NONE,
            classifyAr("com.android.settings", "com.android.settings.applications.InstalledAppDetailsTop", "يوتيوب", "فرض الإيقاف"),
        )
        // Nothing on the screen at all: there is no way to know whose screen it is.
        assertEquals(TamperScreen.NONE, classifyAr("com.android.settings", "com.android.settings.DeviceAdminAdd"))
        // And a class only counts in a system package.
        assertEquals(TamperScreen.NONE, classifyAr("com.whatsapp", "com.android.settings.DeviceAdminAdd", adminAr))
    }

    @Test
    fun `the Arabic word lists classify the four screens without a known class`() {
        // AOSP Arabic wording; the class is an unknown OEM one.
        assertEquals(
            TamperScreen.DEACTIVATE_ADMIN,
            classifyAr("com.android.settings", "com.oem.UnknownSheet", "تطبيقات مشرف الجهاز", adminAr, "إلغاء تنشيط تطبيق مشرف الجهاز هذا", "إلغاء"),
        )
        assertEquals(
            TamperScreen.UNINSTALL,
            classifyAr("com.google.android.packageinstaller", null, "OSRA", "هل تريد إلغاء تثبيت هذا التطبيق؟", "إلغاء", "حسنًا"),
        )
        assertEquals(
            TamperScreen.APP_INFO,
            classifyAr("com.android.settings", null, "معلومات التطبيق", "OSRA", "فرض الإيقاف", "إلغاء التثبيت", "التخزين"),
        )
        assertEquals(
            TamperScreen.APP_INFO,
            classifyAr("com.android.settings", null, "OSRA", "com.familyshield.agent", "محو مساحة التخزين"),
        )
        assertEquals(
            TamperScreen.PRIVATE_DNS,
            classifyAr("com.android.settings", null, "نظام أسماء النطاقات الخاص", "اسم مضيف مزوّد نظام أسماء النطاقات الخاص", "dns.google"),
        )
        // With vowel marks and a tatweel, as some OEM strings render.
        assertEquals(
            TamperScreen.UNINSTALL,
            classifyAr("com.samsung.android.packageinstaller", null, "OSRA", "إِلْغَاء التَّثْبِيـت"),
        )
    }

    @Test
    fun `an unrelated Settings screen in Arabic stays NONE`() {
        assertEquals(
            TamperScreen.NONE,
            classifyAr("com.android.settings", "com.android.settings.SubSettings", "الإعدادات", "الشبكة والإنترنت", "OSRA", "التطبيقات"),
        )
        assertEquals(
            TamperScreen.NONE,
            classifyAr("com.android.settings", null, "تطبيقات مشرف الجهاز", adminAr, "العثور على جهازي"),
        )
    }

    @Test
    fun `normalize folds Arabic vowel marks and hamza forms and leaves English as lowercase`() {
        assertEquals("الغاء التثبيت", TamperScreenPolicy.normalize("إِلْغَاء التَّثْبِيـت"))
        assertEquals("مسوول", TamperScreenPolicy.normalize("مسؤول"))
        assertEquals("deactivate this device admin app", TamperScreenPolicy.normalize("Deactivate this Device Admin app"))
    }

    // ---- osra-security#5 follow-up: the Flip4 capture (One UI, ar-EG and en, build 1998413) ----
    private val samsungSheet = "com.samsung.android.settings.applications.specialaccess.SecDeviceAdminAdd"
    private val aospSheet = "com.android.settings.DeviceAdminAdd"

    private fun classifyFlip(windowClass: String?, adminActive: Boolean, vararg texts: String) =
        TamperScreenPolicy.classify("com.android.settings", texts.toList(), agent, adminAr, pkg, adminActive, windowClass)

    @Test
    fun `the Samsung admin sheet with our admin active is DEACTIVATE_ADMIN, by class and by its Arabic verb`() {
        // By class alone: the sheet names us and shows no listed verb.
        assertEquals(TamperScreen.DEACTIVATE_ADMIN, classifyFlip(samsungSheet, adminActive = true, adminAr, "إلغاء"))
        // By the Flip4's verb alone, with the class unknown.
        assertEquals(
            TamperScreen.DEACTIVATE_ADMIN,
            classifyFlip(null, adminActive = true, "تطبيق مسؤول الجهاز", adminAr, "إلغاء التفعيل", "إلغاء"),
        )
        // Bare «إلغاء» (Cancel) is not a deactivation.
        assertEquals(TamperScreen.NONE, classifyFlip(null, adminActive = true, "تطبيق مسؤول الجهاز", adminAr, "إلغاء"))
    }

    @Test
    fun `the same Samsung sheet with our admin inactive is the activation and stays NONE`() {
        assertEquals(
            TamperScreen.NONE,
            classifyFlip(samsungSheet, adminActive = false, "تطبيق مسؤول الجهاز", adminAr, "إلغاء التفعيل", "إلغاء"),
        )
    }

    @Test
    fun `the AOSP sheet with our admin inactive stays NONE, in either language`() {
        assertEquals(
            TamperScreen.NONE,
            TamperScreenPolicy.classify(
                "com.android.settings",
                listOf("Activate device admin app?", "OSRA parental controls", "Disable some screen lock features", "Activate"),
                agent, admin, pkg, ourAdminActive = false, windowClass = aospSheet,
            ),
        )
        // And with no class at all, the word path does not take the activation sheet's "Disable" for a deactivation.
        assertEquals(
            TamperScreen.NONE,
            TamperScreenPolicy.classify(
                "com.android.settings",
                listOf("Device admin app", "OSRA parental controls", "Disable some screen lock features", "Activate"),
                agent, admin, pkg, ourAdminActive = false,
            ),
        )
    }

    @Test
    fun `the Arabic admin list with its intro text stays NONE`() {
        assertEquals(
            TamperScreen.NONE,
            classifyFlip(
                "com.android.settings.Settings\$DeviceAdminSettingsActivity",
                adminActive = true,
                "تطبيقات مسؤول الجهاز",
                "لإلغاء تفعيل تطبيق مسؤول الجهاز، اختره من القائمة",
                adminAr,
            ),
        )
    }

    @Test
    fun `the Arabic force-stop dialog title is classified`() {
        assertEquals(
            TamperScreen.APP_INFO,
            classifyFlip("androidx.appcompat.app.AlertDialog", adminActive = true, "OSRA", "توقف إجباري؟", "موافق", "إلغاء"),
        )
        // Its title is not the uninstall dialog, even though both are AlertDialogs.
        assertEquals(
            TamperScreen.UNINSTALL,
            TamperScreenPolicy.classify(
                "com.google.android.packageinstaller", listOf("OSRA", "إلغاء التثبيت", "حسنًا", "إلغاء"),
                agent, adminAr, pkg, ourAdminActive = true, windowClass = "android.app.AlertDialog",
            ),
        )
    }

    // osra-security#6 item 3: the screens that create a second space, by package and class from the Flip4
    // capture. Mutants: drop a pair from SPACE_SETUP_SCREENS → its row goes red; match on the class alone
    // → [a same-named class in another package is not a space screen]; match on the package alone → [another
    // screen of the same app is not a space screen].

    private fun classifySpace(packageName: String?, windowClass: String?, vararg texts: String) =
        TamperScreenPolicy.classify(packageName, texts.toList(), agent, admin, pkg, ourAdminActive = false, windowClass = windowClass)

    @Test
    fun `Dual Messenger's app list is SPACE_SETUP, without naming us and in any language`() {
        val cls = "com.samsung.android.da.daagent.activity.DualAppActivity"
        assertEquals(TamperScreen.SPACE_SETUP, classifySpace("com.samsung.android.da.daagent", cls, "Dual Messenger", "WhatsApp"))
        assertEquals(TamperScreen.SPACE_SETUP, classifySpace("com.samsung.android.da.daagent", cls, "المراسلة المزدوجة"))
        assertEquals("no text on screen yet", TamperScreen.SPACE_SETUP, classifySpace("com.samsung.android.da.daagent", cls))
    }

    @Test
    fun `Secure Folder's setup is SPACE_SETUP`() {
        val cls = "com.samsung.knox.securefolder.provisioning.setup.view.WelcomeActivity"
        assertEquals(TamperScreen.SPACE_SETUP, classifySpace("com.samsung.knox.securefolder", cls, "Secure Folder", "Agree"))
    }

    @Test
    fun `a same-named class in another package is not a space screen`() {
        assertEquals(TamperScreen.NONE, classifySpace("com.example.app", "com.example.app.WelcomeActivity", "Welcome"))
        assertEquals(TamperScreen.NONE, classifySpace("com.example.app", "com.example.DualAppActivity", "Dual"))
    }

    @Test
    fun `another screen of the same app is not a space screen`() {
        assertEquals(TamperScreen.NONE, classifySpace("com.samsung.knox.securefolder", "com.samsung.knox.securefolder.SettingsActivity", "Secure Folder"))
        assertEquals(TamperScreen.NONE, classifySpace("com.samsung.android.da.daagent", null, "Dual Messenger"))
    }

    @Test
    fun `the guard steps in for a space screen like any other`() {
        assertTrue(TamperScreenPolicy.shouldGuard(TamperScreen.SPACE_SETUP, pinConfigured = true, graceUntilMs = 0L, nowMs = 1L))
        assertFalse(TamperScreenPolicy.shouldGuard(TamperScreen.SPACE_SETUP, pinConfigured = true, graceUntilMs = 2L, nowMs = 1L))
    }

    /**
     * Part 2 of osra-security#29: the sibling special-access pages. Each names us and carries its own phrase; each is
     * a protection screen **only while we hold that access**, because onboarding opens the same page to grant it.
     */
    @Test
    fun `a special-access page we already hold is guarded`() {
        fun classify(access: Set<TamperScreenPolicy.SpecialAccess>, vararg texts: String) =
            TamperScreenPolicy.classify(
                "com.android.settings",
                texts.toList(),
                agent, admin, pkg,
                ourAdminActive = true,
                ourSpecialAccess = access,
            )
        val cases = mapOf(
            TamperScreenPolicy.SpecialAccess.OVERLAY to "Display over other apps",
            TamperScreenPolicy.SpecialAccess.USAGE to "Usage access",
            TamperScreenPolicy.SpecialAccess.NOTIFICATIONS to "Notification access",
            // the management phrase, not the three letters: bare "vpn" was tightened out on Antigravity's note
            TamperScreenPolicy.SpecialAccess.VPN to "Always-on VPN",
        )
        for ((access, phrase) in cases) {
            assertEquals(
                "$access",
                TamperScreen.SPECIAL_ACCESS,
                classify(setOf(access), "OSRA", phrase, "Allowed"),
            )
            assertEquals(
                "$access, not held yet — this is the grant",
                TamperScreen.NONE,
                classify(emptySet(), "OSRA", phrase, "Allowed"),
            )
        }
    }

    /** A page for an access we do not hold is the parent granting it, whatever else the screen says. */
    @Test
    fun `a special-access page naming another app stays NONE`() {
        assertEquals(
            TamperScreen.NONE,
            TamperScreenPolicy.classify(
                "com.android.settings",
                listOf<CharSequence>("Chrome", "Display over other apps", "Allowed"),
                agent, admin, pkg,
                ourAdminActive = true,
                ourSpecialAccess = setOf(TamperScreenPolicy.SpecialAccess.OVERLAY),
            ),
        )
    }

    /**
     * Antigravity's second note on Part 2: the SPECIAL_ACCESS branch is scoped to Settings, and the VPN words name
     * the management actions rather than the letters.
     */
    @Test
    fun `a third-party VPN on a Settings page is not our protection screen`() {
        assertNotEquals(
            TamperScreen.SPECIAL_ACCESS,
            TamperScreenPolicy.classify(
                "com.android.settings",
                listOf<CharSequence>("OSRA", "ProtonVPN", "OpenVPN", "VPN"),
                agent, admin, pkg,
                ourAdminActive = true,
                ourSpecialAccess = setOf(TamperScreenPolicy.SpecialAccess.VPN),
            ),
        )
        // The management action does count.
        assertEquals(
            TamperScreen.SPECIAL_ACCESS,
            TamperScreenPolicy.classify(
                "com.android.settings",
                listOf<CharSequence>("OSRA", "Always-on VPN", "Forget VPN"),
                agent, admin, pkg,
                ourAdminActive = true,
                ourSpecialAccess = setOf(TamperScreenPolicy.SpecialAccess.VPN),
            ),
        )
        // And the branch never fires outside Settings.
        assertEquals(
            TamperScreen.NONE,
            TamperScreenPolicy.classify(
                "com.android.permissioncontroller",
                listOf<CharSequence>("OSRA", "Usage access"),
                agent, admin, pkg,
                ourAdminActive = true,
                ourSpecialAccess = setOf(TamperScreenPolicy.SpecialAccess.USAGE),
            ),
        )
    }

    /**
     * Antigravity's item 4: OSRA's App Info screen carries a "Display over other apps" summary row, so a word-first
     * special-access check reclassified it from APP_INFO to SPECIAL_ACCESS and the parent's alert said "special
     * access" for an page that was app info. A class-identified screen keeps its identity.
     */
    @Test
    fun `App info with an overlay row is still APP_INFO`() {
        assertEquals(
            TamperScreen.APP_INFO,
            TamperScreenPolicy.classify(
                "com.android.settings",
                listOf<CharSequence>("OSRA", "Appear on top", "Uninstall", "Force stop"),
                agent, admin, pkg,
                ourAdminActive = true,
                windowClass = "AppInfoDashboardActivity",
                ourSpecialAccess = setOf(TamperScreenPolicy.SpecialAccess.OVERLAY),
            ),
        )
        // And the fragment-hosted page, with no class to name it, still falls through to SPECIAL_ACCESS.
        assertEquals(
            TamperScreen.SPECIAL_ACCESS,
            TamperScreenPolicy.classify(
                "com.android.settings",
                listOf<CharSequence>("OSRA", "Display over other apps", "Allowed"),
                agent, admin, pkg,
                ourAdminActive = true,
                windowClass = "SubSettings",
                ourSpecialAccess = setOf(TamperScreenPolicy.SpecialAccess.OVERLAY),
            ),
        )
    }

    /**
     * Arabic Language Bureau, review of #817: the four phrase lists carried no Arabic row at all, so nothing failed if
     * a phrase was wrong. Each row feeds the screen's own Arabic through `classify()`, and each phrase is Google's,
     * taken from `platform/packages/apps/Settings` `values-ar` (12 to 16) and folded with `normalize()`.
     *
     * Mutant: change a letter of any phrase in the policy → the row that feeds the real screen text goes red.
     */
    @Test
    fun `the Arabic phrases match the screens they were taken from`() {
        fun classifyAr(address: Set<TamperScreenPolicy.SpecialAccess>, vararg texts: String) =
            TamperScreenPolicy.classify(
                "com.android.settings", texts.toList(), agent, admin, pkg,
                ourAdminActive = true, ourSpecialAccess = address,
            )
        // 12–15 title and switch, 16 title
        assertEquals(
            "overlay 12-15 title",
            TamperScreen.SPECIAL_ACCESS,
            classifyAr(setOf(TamperScreenPolicy.SpecialAccess.OVERLAY), "OSRA", "إظهار فوق التطبيقات الأخرى", "مسموح"),
        )
        assertEquals(
            "overlay 12-15 switch",
            TamperScreen.SPECIAL_ACCESS,
            classifyAr(setOf(TamperScreenPolicy.SpecialAccess.OVERLAY), "OSRA", "السماح بظهور التطبيق فوق التطبيقات الأخرى"),
        )
        assertEquals(
            "overlay 16 title",
            TamperScreen.SPECIAL_ACCESS,
            classifyAr(setOf(TamperScreenPolicy.SpecialAccess.OVERLAY), "OSRA", "الظهور فوق التطبيقات الأخرى"),
        )
        // 12–15 usage access title
        assertEquals(
            "usage 12-15",
            TamperScreen.SPECIAL_ACCESS,
            classifyAr(setOf(TamperScreenPolicy.SpecialAccess.USAGE), "OSRA", "الوصول إلى بيانات الاستخدام"),
        )
    }

    /** The Bureau's point about direction marks: Google's Arabic lines that name a Latin word carry U+200F first. */
    @Test
    fun `a direction mark does not break a phrase`() {
        assertEquals(
            TamperScreen.SPECIAL_ACCESS,
            TamperScreenPolicy.classify(
                "com.android.settings",
                // the mark is INSIDE the phrase: with it only at the start, `contains` would match anyway
                listOf<CharSequence>("OSRA", "الظهور فوق‏ التطبيقات الأخرى", "مسموح"),
                agent, admin, pkg,
                ourAdminActive = true,
                ourSpecialAccess = setOf(TamperScreenPolicy.SpecialAccess.OVERLAY),
            ),
        )
    }

    /**
     * And U+061C, the Arabic letter mark, which `normalize()` drops for the same reason. The mark sits inside the
     * phrase, so the row fails if the strip is removed.
     */
    @Test
    fun `the Arabic letter mark does not break a phrase`() {
        assertEquals(
            TamperScreen.SPECIAL_ACCESS,
            TamperScreenPolicy.classify(
                "com.android.settings",
                listOf<CharSequence>("OSRA", "الوصول إلى بيانات\u061C استخدام التطبيق", "مسموح"),
                agent, admin, pkg,
                ourAdminActive = true,
                ourSpecialAccess = setOf(TamperScreenPolicy.SpecialAccess.USAGE),
            ),
        )
    }

    /**
     * Antigravity's Flip4 pass at `e131c080` (One UI 8.0, ar-AE): the four special-access lists each have a **Search
     * apps** bar, and opening it replaces the toolbar title with "Search apps", so the phrase that identified the page
     * was gone and the child could toggle us off with no PIN. The five list pages have their own activity classes, so
     * the class identifies them whatever the toolbar says and in any language — the texts here match **no** phrase in
     * `SPECIAL_ACCESS_WORDS`, which is the whole point.
     *
     * Mutant: drop `SPECIAL_ACCESS_CLASSES` from `classify()` → every row below returns NONE.
     */
    @Test
    fun `a special-access page is identified by its class while the search bar hides the title`() {
        fun byClass(cls: String, access: TamperScreenPolicy.SpecialAccess) =
            TamperScreenPolicy.classify(
                "com.android.settings",
                // what the screen shows while "Search apps" has replaced the title: our name in the result row and
                // nothing else that any word list knows
                listOf<CharSequence>("OSRA", "Search apps", "Apps"),
                agent, admin, pkg,
                ourAdminActive = true,
                ourSpecialAccess = setOf(access),
                windowClass = cls,
            )
        val cases = mapOf(
            "com.android.settings.Settings\$OverlaySettingsActivity" to TamperScreenPolicy.SpecialAccess.OVERLAY,
            "com.android.settings.Settings\$UsageAccessSettingsActivity" to TamperScreenPolicy.SpecialAccess.USAGE,
            "com.android.settings.Settings\$AppUsageAccessSettingsActivity" to TamperScreenPolicy.SpecialAccess.USAGE,
            "com.android.settings.Settings\$NotificationAccessSettingsActivity" to TamperScreenPolicy.SpecialAccess.NOTIFICATIONS,
            "com.android.settings.Settings\$NotificationAccessDetailsActivity" to TamperScreenPolicy.SpecialAccess.NOTIFICATIONS,
        )
        for ((cls, access) in cases) {
            assertEquals("$access by class", TamperScreen.SPECIAL_ACCESS, byClass(cls, access))
        }
        // An access we do not hold is the parent granting it, whatever the class says.
        assertEquals(
            "the grant, not the tamper",
            TamperScreen.NONE,
            TamperScreenPolicy.classify(
                "com.android.settings",
                listOf<CharSequence>("OSRA", "Search apps", "Apps"),
                agent, admin, pkg,
                ourAdminActive = true,
                ourSpecialAccess = emptySet(),
                windowClass = "com.android.settings.Settings\$OverlaySettingsActivity",
            ),
        )
        // And the same class in another package is not a Settings page.
        assertEquals(
            "not a Settings screen",
            TamperScreen.NONE,
            TamperScreenPolicy.classify(
                "com.example.other",
                listOf<CharSequence>("OSRA", "Search apps", "Apps"),
                agent, admin, pkg,
                ourAdminActive = true,
                ourSpecialAccess = setOf(TamperScreenPolicy.SpecialAccess.OVERLAY),
                windowClass = "com.android.settings.Settings\$OverlaySettingsActivity",
            ),
        )
    }

    /**
     * The same pass's other half: the VPN gear page is `SubSettings` and split-screen passes a null class, so those
     * still depend on words — the ones Antigravity quoted from the dump, told apart by the fact that they name a
     * management action.
     */
    @Test
    fun `the Flip4 VPN gear page and search results are guarded by their own words`() {
        fun words(access: TamperScreenPolicy.SpecialAccess, vararg texts: String) =
            TamperScreenPolicy.classify(
                "com.android.settings", texts.toList(), agent, admin, pkg,
                ourAdminActive = true, ourSpecialAccess = setOf(access),
                windowClass = "com.android.settings.SubSettings",
            )
        // English gear page: the switch that keeps the filter on
        assertEquals(TamperScreen.SPECIAL_ACCESS, words(TamperScreenPolicy.SpecialAccess.VPN, "OSRA", "Always-on VPN"))
        // Claude's smaller item: "block connections without vpn" gets its own row. Asserted beside "Always-on VPN"
        // it could be deleted and the row would still pass, which is the shape we keep having to fix.
        assertEquals(
            "the block-connections row",
            TamperScreen.SPECIAL_ACCESS,
            words(TamperScreenPolicy.SpecialAccess.VPN, "OSRA", "Block connections without VPN"),
        )
        // ar-AE gear page: the switch, the block row, and the delete row that opens the confirm sheet
        for (phrase in listOf("تشغيل VPN دائمًا", "حظر الاتصالات من دون VPN", "حذف ملف تعريف VPN")) {
            assertEquals(phrase, TamperScreen.SPECIAL_ACCESS, words(TamperScreenPolicy.SpecialAccess.VPN, "OSRA", phrase))
        }
        // Search results, English: the row's function description, with the page title replaced by "Search apps"
        assertEquals(
            "overlay search row",
            TamperScreen.SPECIAL_ACCESS,
            words(TamperScreenPolicy.SpecialAccess.OVERLAY, "OSRA", "Search apps", "Show things on top of other apps"),
        )
        assertEquals(
            "usage search row",
            TamperScreen.SPECIAL_ACCESS,
            words(TamperScreenPolicy.SpecialAccess.USAGE, "OSRA", "Search apps", "Monitor which other apps you use"),
        )
        // and the same two rows in ar-AE, with the wording the dump shows
        assertEquals(
            "overlay search row, Arabic",
            TamperScreen.SPECIAL_ACCESS,
            words(TamperScreenPolicy.SpecialAccess.OVERLAY, "OSRA", "عرض المحتويات فوق تطبيقات أخرى"),
        )
        assertEquals(
            "usage search row, Arabic",
            TamperScreen.SPECIAL_ACCESS,
            words(TamperScreenPolicy.SpecialAccess.USAGE, "OSRA", "بمراقبة التطبيقات الأخرى التي تستخدمها"),
        )
        // One UI 8.0's own list titles, which omit «إلى» and say «الأعلى» rather than «فوق»
        assertEquals(
            "overlay title, One UI",
            TamperScreen.SPECIAL_ACCESS,
            words(TamperScreenPolicy.SpecialAccess.OVERLAY, "OSRA", "الظهور في الأعلى"),
        )
        assertEquals(
            "usage title, One UI",
            TamperScreen.SPECIAL_ACCESS,
            words(TamperScreenPolicy.SpecialAccess.USAGE, "OSRA", "وصول بيانات الاستخدام"),
        )
    }

    /** Each phrase the Arabic Language Bureau confirmed, fed through `classify()` as the screen shows it. */
    @Test
    fun `every confirmed Arabic phrase is guarded`() {
        fun ar(access: TamperScreenPolicy.SpecialAccess, vararg texts: String) =
            TamperScreenPolicy.classify(
                "com.android.settings", texts.toList(), agent, admin, pkg,
                ourAdminActive = true, ourSpecialAccess = setOf(access),
            )
        // notifications: the switch, 12–16
        assertEquals(
            TamperScreen.SPECIAL_ACCESS,
            ar(TamperScreenPolicy.SpecialAccess.NOTIFICATIONS, "OSRA", "الوصول إلى الإشعارات", "مسموح"),
        )
        // usage: 16 title and switch
        assertEquals(
            TamperScreen.SPECIAL_ACCESS,
            ar(TamperScreenPolicy.SpecialAccess.USAGE, "OSRA", "الوصول إلى بيانات استخدام التطبيق"),
        )
        // overlay: the 12–16 switch form
        assertEquals(
            TamperScreen.SPECIAL_ACCESS,
            ar(TamperScreenPolicy.SpecialAccess.OVERLAY, "OSRA", "بظهور التطبيق فوق التطبيقات الأخرى"),
        )
    }

    /** And each new English phrase, in the spelling the screens use. */
    @Test
    fun `every new English phrase is guarded`() {
        fun en(access: TamperScreenPolicy.SpecialAccess, vararg texts: String) =
            TamperScreenPolicy.classify(
                "com.android.settings", texts.toList(), agent, admin, pkg,
                ourAdminActive = true, ourSpecialAccess = setOf(access),
            )
        for (phrase in listOf("App usage data", "Permit access to app usage data")) {
            assertEquals(phrase, TamperScreen.SPECIAL_ACCESS, en(TamperScreenPolicy.SpecialAccess.USAGE, "OSRA", phrase))
        }
        for (phrase in listOf("Device & app notifications", "Notification read, reply & control")) {
            assertEquals(phrase, TamperScreen.SPECIAL_ACCESS, en(TamperScreenPolicy.SpecialAccess.NOTIFICATIONS, "OSRA", phrase))
        }
    }

    /**
     * The VPN management pages, one row per phrase the Bureau quoted (private note on osra-security#29, 2026-11-15).
     * Each row feeds the string as the page renders it, so removing or misspelling that phrase in the policy turns the
     * row red — which is what "the phrase is listed" has to mean if it is to mean anything.
     *
     * Mutant: delete `نسيان شبكة vpn` from the policy → the "forget network" row goes NONE.
     */
    @Test
    fun `each Arabic VPN management phrase is guarded`() {
        fun vpn(vararg texts: String) =
            TamperScreenPolicy.classify(
                "com.android.settings", texts.toList(), agent, admin, pkg,
                ourAdminActive = true, ourSpecialAccess = setOf(TamperScreenPolicy.SpecialAccess.VPN),
            )
        val phrases = listOf(
            "always-on, 12" to "شبكة VPN قيد التشغيل دائمًا",
            "always-on, short form" to "VPN) قيد التشغيل دائمًا",
            "always-on, 14-16" to "VPN) دائمة التفعيل",
            "forget, 12-14" to "نسيان شبكة VPN",
            "forget, 15-16" to "نسيان الشبكة الافتراضية الخاصة",
            "profile, 12-14" to "ملف شبكة VPN",
            "profile, 15-16" to "ملف الشبكة الافتراضية الخاصة",
            "stay connected, all" to "متابعة الاتصال بشبكة VPN في جميع الأوقات",
        )
        for ((label, phrase) in phrases) {
            assertEquals(label, TamperScreen.SPECIAL_ACCESS, vpn("OSRA", phrase, "مسموح"))
            // The same page for an access we do not hold is the grant, not the tamper.
            assertEquals(
                "$label, not held yet",
                TamperScreen.NONE,
                TamperScreenPolicy.classify(
                    "com.android.settings", listOf<CharSequence>("OSRA", phrase, "مسموح"), agent, admin, pkg,
                    ourAdminActive = true, ourSpecialAccess = emptySet(),
                ),
            )
        }
    }

    /**
     * Arabic Language Bureau, via Claude's note on #817: «الظهور في الأعلى» is a short, common phrase, and it is safe
     * as a trigger **only** because the page must also name the agent. This is the row that keeps that true.
     *
     * Mutant: drop the `namesUs` guard in `classify()` → this row raises the gate on someone else's page.
     */
    @Test
    fun `the short Arabic overlay phrase alone does not guard another app's page`() {
        assertEquals(
            TamperScreen.NONE,
            TamperScreenPolicy.classify(
                "com.android.settings",
                listOf<CharSequence>("Chrome", "الظهور في الأعلى", "مسموح"),
                agent, admin, pkg,
                ourAdminActive = true,
                ourSpecialAccess = setOf(TamperScreenPolicy.SpecialAccess.OVERLAY),
                windowClass = "com.android.settings.SubSettings",
            ),
        )
        // The positive control: the same text with our name on it does guard.
        assertEquals(
            TamperScreen.SPECIAL_ACCESS,
            TamperScreenPolicy.classify(
                "com.android.settings",
                listOf<CharSequence>("OSRA", "الظهور في الأعلى", "مسموح"),
                agent, admin, pkg,
                ourAdminActive = true,
                ourSpecialAccess = setOf(TamperScreenPolicy.SpecialAccess.OVERLAY),
                windowClass = "com.android.settings.SubSettings",
            ),
        )
    }
}
