package com.familyshield.agent.setup

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File

/**
 * Issue #1131: Android 13+ non-store install "Allow restricted settings" guidance and live-bound
 * Accessibility completion check.
 *
 * Mutants:
 * - Return true for Play Store (`com.android.vending`) or Play flavor -> store/Play tests go red.
 * - Return true below API 33 -> Android 12 test goes red.
 * - Ignore `isServiceRunning` in `isAccessibilityBoundAndEnabled` -> listed-but-unbound test goes red.
 */
class RestrictedSettingsPolicyTest {

    private val pkg = "com.osratech.child.full"
    private val service = "com.familyshield.agent.services.AccessibilityMonitorService"
    private val enabledList = "$pkg/$service"

    @Test
    fun `sideloaded Full build on Android 13+ shows the restricted settings guide`() {
        assertTrue(RestrictedSettingsPolicy.requiresGuide(sdkInt = 33, installerPackageName = null, isPlayBuild = false))
        assertTrue(RestrictedSettingsPolicy.requiresGuide(sdkInt = 34, installerPackageName = "com.google.android.packageinstaller", isPlayBuild = false))
        assertTrue(RestrictedSettingsPolicy.requiresGuide(sdkInt = 35, installerPackageName = "com.miui.packageinstaller", isPlayBuild = false))
        assertTrue(RestrictedSettingsPolicy.requiresGuide(sdkInt = 33, installerPackageName = "com.android.shell", isPlayBuild = false))
    }

    @Test
    fun `store installs and Play flavor never show the restricted settings guide`() {
        assertFalse(RestrictedSettingsPolicy.requiresGuide(sdkInt = 34, installerPackageName = "com.android.vending", isPlayBuild = false))
        assertFalse(RestrictedSettingsPolicy.requiresGuide(sdkInt = 34, installerPackageName = "com.sec.android.app.samsungapps", isPlayBuild = false))
        assertFalse(RestrictedSettingsPolicy.requiresGuide(sdkInt = 34, installerPackageName = "com.xiaomi.mipicks", isPlayBuild = false))
        assertFalse(RestrictedSettingsPolicy.requiresGuide(sdkInt = 34, installerPackageName = null, isPlayBuild = true))
    }

    @Test
    fun `Android 12 and older never show the restricted settings guide`() {
        assertFalse(RestrictedSettingsPolicy.requiresGuide(sdkInt = 32, installerPackageName = null, isPlayBuild = false))
        assertFalse(RestrictedSettingsPolicy.requiresGuide(sdkInt = 31, installerPackageName = "com.miui.packageinstaller", isPlayBuild = false))
    }

    @Test
    fun `accessibility completes only when both listed in Settings and actively bound`() {
        // Listed in Settings.Secure, but service is NOT bound yet -> incomplete.
        assertFalse(
            RestrictedSettingsPolicy.isAccessibilityBoundAndEnabled(
                enabledServicesSetting = enabledList,
                packageName = pkg,
                serviceClassName = service,
                isServiceRunning = false,
            ),
        )
        // Bound flag true, but Settings list missing -> incomplete.
        assertFalse(
            RestrictedSettingsPolicy.isAccessibilityBoundAndEnabled(
                enabledServicesSetting = null,
                packageName = pkg,
                serviceClassName = service,
                isServiceRunning = true,
            ),
        )
        // Both listed and bound -> complete.
        assertTrue(
            RestrictedSettingsPolicy.isAccessibilityBoundAndEnabled(
                enabledServicesSetting = enabledList,
                packageName = pkg,
                serviceClassName = service,
                isServiceRunning = true,
            ),
        )
    }

    @Test
    fun `service label is wrapped in Unicode FSI and PDI for Arabic RTL isolation`() {
        assertEquals("\u2068OSRA accessibility\u2069", RestrictedSettingsPolicy.isolateServiceLabel(" OSRA accessibility "))
    }

    @Test
    fun `GrantChecks and PairingActivity wire the live bound check and App info button`() {
        val root = findAppSrcRoot()
        val grantChecks = File(root, "java/com/familyshield/agent/setup/GrantChecks.kt").readText()
        val activity = File(root, "java/com/familyshield/agent/setup/PairingActivity.kt").readText()
        val enStrings = File(root, "res/values/strings.xml").readText()
        val arStrings = File(root, "res/values-ar/strings.xml").readText()

        assertTrue(grantChecks.contains("RestrictedSettingsPolicy.isAccessibilityBoundAndEnabled"))
        assertTrue(grantChecks.contains("AccessibilityMonitorService.isRunning"))
        assertTrue(grantChecks.contains("RestrictedSettingsPolicy.appInfoIntent"))

        assertTrue(activity.contains("RestrictedSettingsPolicy.requiresGuide"))
        assertTrue(activity.contains("RestrictedSettingsPolicy.isolateServiceLabel"))
        assertTrue(activity.contains("grants.appInfoIntent()"))

        for (key in listOf(
            "restricted_settings_step_1",
            "restricted_settings_open_app_info",
            "restricted_settings_step_2",
            "restricted_settings_step_3",
            "restricted_settings_waiting",
        )) {
            assertTrue("EN strings missing $key", enStrings.contains("name=\"$key\""))
            assertTrue("AR strings missing $key", arStrings.contains("name=\"$key\""))
        }
        // Arabic Bureau #1131 (7168407917): no "top right" direction hardcoding and no Latin "Android".
        assertTrue(arStrings.contains("في أعلى الشاشة"))
        assertTrue(arStrings.contains("السماح بالإعدادات المحظورة"))
    }

    private fun findAppSrcRoot(): File {
        var dir = File(System.getProperty("user.dir") ?: ".")
        repeat(5) {
            val candidate = File(dir, "src/main")
            if (candidate.isDirectory) return candidate
            val nested = File(dir, "app/src/main")
            if (nested.isDirectory) return nested
            dir = dir.parentFile ?: return candidate
        }
        return File("src/main")
    }
}
