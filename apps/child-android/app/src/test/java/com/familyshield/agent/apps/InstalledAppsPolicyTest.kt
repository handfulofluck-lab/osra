package com.familyshield.agent.apps

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Roadmap 3.4: the pure installed-app list builder. These are the rules the server relies on, pinned
 * without a device: launcher-only, one row per package, label fallback/cap, system flag, and the
 * 500-app cap.
 */
class InstalledAppsPolicyTest {

    @Test
    fun `only launchable entries survive`() {
        val report = InstalledAppsPolicy.build(
            listOf(
                LauncherApp("com.example.launcher", "Launcher app", isSystem = false),
                LauncherApp("com.example.hidden", "Not on the launcher", isSystem = false, launchable = false),
                LauncherApp("com.android.settings", "Settings", isSystem = true),
            ),
        )
        assertEquals(listOf("com.example.launcher", "com.android.settings"), report.apps.map { it.packageId })
        assertFalse(report.truncated)
    }

    @Test
    fun `a package with several launcher activities appears once and the first label wins`() {
        val report = InstalledAppsPolicy.build(
            listOf(
                LauncherApp("com.example.maps", "Maps", isSystem = false),
                LauncherApp("com.example.maps", "Maps (shortcut)", isSystem = false),
                LauncherApp(" com.example.maps ", "Maps duplicate", isSystem = true),
            ),
        )
        assertEquals(1, report.apps.size)
        assertEquals("com.example.maps", report.apps.single().packageId)
        assertEquals("Maps", report.apps.single().label)
        assertFalse(report.apps.single().isSystem)
    }

    @Test
    fun `a blank label falls back to the package id and labels are trimmed`() {
        val report = InstalledAppsPolicy.build(
            listOf(
                LauncherApp("com.example.blank", "   ", isSystem = false),
                LauncherApp("com.example.padded", "  Padded name  ", isSystem = false),
                LauncherApp("   ", "Dropped", isSystem = false),
            ),
        )
        assertEquals(listOf("com.example.blank", "com.example.padded"), report.apps.map { it.packageId })
        assertEquals("com.example.blank", report.apps[0].label)
        assertEquals("Padded name", report.apps[1].label)
    }

    @Test
    fun `the system flag is preserved`() {
        val report = InstalledAppsPolicy.build(
            listOf(
                LauncherApp("com.android.settings", "Settings", isSystem = true),
                LauncherApp("com.example.game", "Game", isSystem = false),
            ),
        )
        val byPackage = report.apps.associateBy { it.packageId }
        assertTrue(byPackage.getValue("com.android.settings").isSystem)
        assertFalse(byPackage.getValue("com.example.game").isSystem)
    }

    @Test
    fun `labels are capped at 100 characters`() {
        val report = InstalledAppsPolicy.build(
            listOf(LauncherApp("com.example.long", "x".repeat(120), isSystem = false)),
        )
        assertEquals(InstalledAppsPolicy.MAX_LABEL, report.apps.single().label.length)
    }

    @Test
    fun `more than 500 apps are capped, sorted by label, and marked truncated`() {
        val candidates = (0 until 510).map {
            // Reverse order on purpose: PackageManager order is not contractual.
            LauncherApp("com.example.app${509 - it}", "App ${509 - it}", isSystem = false)
        }
        val report = InstalledAppsPolicy.build(candidates)
        assertEquals(InstalledAppsPolicy.MAX_APPS, report.apps.size)
        assertTrue(report.truncated)
        // Lexicographic label order: "App 100" < "App 11" < "App 2" ... so just assert it is sorted
        // by the same comparator the policy uses, not by a hand-written expectation.
        val labels = report.apps.map { it.label.lowercase() }
        assertEquals(labels.sorted(), labels)
    }

    @Test
    fun `fingerprint is stable across input order and changes with the system flag`() {
        val a = LauncherApp("com.example.a", "A", isSystem = false)
        val b = LauncherApp("com.example.b", "B", isSystem = true)
        val first = InstalledAppsPolicy.fingerprint(InstalledAppsPolicy.build(listOf(a, b)).apps)
        val reordered = InstalledAppsPolicy.fingerprint(InstalledAppsPolicy.build(listOf(b, a)).apps)
        assertEquals(first, reordered)

        val flipped = InstalledAppsPolicy.fingerprint(
            InstalledAppsPolicy.build(listOf(a.copy(isSystem = true), b)).apps,
        )
        assertNotEquals(first, flipped)
        assertEquals(64, first.length)
        assertTrue(first.matches(Regex("[0-9a-f]+")))
    }
}
