package com.familyshield.agent.apps

import com.familyshield.agent.enforcement.PackageFacts
import java.io.File
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Karim, 23 Nov: the Parent Apps tab shows each app's real icon, so the installed-apps report carries
 * it. The suite has no Robolectric, so the PackageManager half is pinned through the source, and the
 * budget rule through the pure function.
 */
class AppIconReportTest {

    private val facts = object : PackageFacts {
        override fun isSystemApp(pkg: String): Boolean = false
        override fun dialerRoleHolders(): Set<String> = emptySet()
        override fun homePackages(): Set<String> = emptySet()
    }

    @Test
    fun `an icon travels on the inventory row, and a missing one is omitted`() {
        assertEquals("aWNvbg==", inventoryApp("com.example.a", "A", false, facts, "aWNvbg==").icon)
        assertNull(inventoryApp("com.example.b", "B", false, facts).icon)
    }

    @Test
    fun `icons over the per-app cap or the report budget are left out, in list order`() {
        val kept = AppIconEncoder.withinBudget(
            listOf(
                "a" to "x".repeat(4),
                "b" to null,
                "c" to "x".repeat(11), // over maxEach
                "d" to "x".repeat(4),
                "e" to "x".repeat(4), // would exceed maxTotal
                "f" to "x".repeat(2), // still fits
            ),
            maxEach = 10,
            maxTotal = 10,
        )
        assertEquals(listOf("a", "d", "f"), kept.keys.toList())
    }

    @Test
    fun `the per-app cap matches the server's`() {
        // services/api/src/routes/devices.ts MAX_APP_ICON_BASE64
        val server = File(repoRoot(), "services/api/src/routes/devices.ts").readText()
        assertTrue(server.contains("MAX_APP_ICON_BASE64 = 12_000"))
        assertEquals(12_000, AppIconEncoder.MAX_ICON_BASE64)
    }

    @Test
    fun `icons are encoded only on an upload, and the first icon report goes out without waiting a day`() {
        val src = File(repoRoot(), "apps/child-android/app/src/main/java/com/familyshield/agent/apps/InstalledAppsReporter.kt").readText()
        val unchanged = src.indexOf("if (unchanged) return")
        val encode = src.indexOf("AppIconEncoder.encodeAll(")
        assertTrue("icons are encoded after the unchanged check", unchanged in 0 until encode)
        assertTrue(src.contains("InstalledAppsPolicy.fingerprint(report.apps) + ICONS_MARKER"))
        assertTrue(src.contains("icons[it.packageId]"))
    }

    private fun repoRoot(): File {
        var dir: File? = File(".").absoluteFile
        while (dir != null && !File(dir, "services/api").isDirectory) dir = dir.parentFile
        return requireNotNull(dir) { "repo root not found" }
    }
}
