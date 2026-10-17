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
        TamperScreenPolicy.classify(packageName, texts.toList(), agent, admin, pkg)

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
}
