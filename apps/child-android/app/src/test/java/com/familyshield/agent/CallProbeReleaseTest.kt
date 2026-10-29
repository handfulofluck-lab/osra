package com.familyshield.agent

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File

/**
 * Issue #444: `CallProbe` is a measurement for debug builds. It subscribes to notification events,
 * registers an exported receiver and can draw a full-screen cover, none of which a release build may do.
 * Every public entry point must therefore return at once unless `BuildConfig.DEBUG`; and the shipped
 * accessibility config must not ask for notification events (the probe adds them at runtime).
 *
 * The unit suite has no AGP model, so this reads the sources as text, as `LocationServiceStartSitesTest` does.
 */
class CallProbeReleaseTest {

    private fun file(relative: String): File {
        var dir: File? = File(System.getProperty("user.dir")).absoluteFile
        while (dir != null) {
            val candidate = File(dir, relative)
            if (candidate.isFile) return candidate
            dir = dir.parentFile
        }
        throw AssertionError("could not find $relative from ${System.getProperty("user.dir")}")
    }

    @Test
    fun `every CallProbe entry point is a no-op outside a debug build`() {
        val text = file("app/src/main/java/com/familyshield/agent/services/CallProbe.kt").readText()
        val entryPoints = Regex("""\n    fun (\w+)\([^{]*\{\n\s*(.*)\n""").findAll(text).map { it.groupValues[1] to it.groupValues[2].trim() }.toList()

        assertEquals(listOf("onConnected", "onDisconnected", "onNotification", "onWindows"), entryPoints.map { it.first })
        entryPoints.forEach { (name, firstLine) ->
            assertEquals("$name must start with the debug guard", "if (!BuildConfig.DEBUG) return", firstLine)
        }
    }

    @Test
    fun `the shipped accessibility config does not subscribe to notifications`() {
        val config = file("app/src/main/res/xml/accessibility_config.xml").readText()
        assertTrue(config.contains("accessibilityEventTypes"))
        assertFalse(config.contains("typeNotificationStateChanged"))
        assertFalse(config.contains("typeAllMask"))
    }
}
