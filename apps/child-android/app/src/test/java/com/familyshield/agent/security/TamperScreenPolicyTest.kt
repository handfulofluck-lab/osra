package com.familyshield.agent.security

import org.junit.Assert.assertEquals
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
}
