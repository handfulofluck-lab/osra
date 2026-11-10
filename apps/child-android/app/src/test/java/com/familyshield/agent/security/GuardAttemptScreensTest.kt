package com.familyshield.agent.security

import java.io.File
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * osra-security#6 (Flip4, 10 Nov): inside an open five-minute window, a second kind of attempt (setting up a
 * second space after a device-admin attempt) only raised the count, so the parent never saw the new reason.
 * The window now keeps each distinct screen, and the aggregate body names them all.
 *
 * Mutants: `record` keeps only the first screen → [a new screen in an open window is kept]; the body drops the
 * list → [the aggregate body names every screen tried]; the service stops passing the screen, or the worker
 * stops carrying the list, or the load returns no screens → [the screen travels from the guard to the alert body];
 * decode drops an item → [the saved list comes back after a restart]; a kind without a label →
 * [every screen kind has a label the parent can read].
 */
class GuardAttemptScreensTest {

    private val t0 = 1_700_000_000_000L

    @Test
    fun `a new screen in an open window is kept`() {
        val a = GuardAttemptWindow.record(null, t0, "deactivate_admin")
        val b = GuardAttemptWindow.record(a.state, t0 + 10_000, "deactivate_admin")
        val c = GuardAttemptWindow.record(b.state, t0 + 20_000, "space_setup")
        assertEquals(3, c.state.count)
        assertEquals(listOf("deactivate_admin", "space_setup"), c.state.screens)
    }

    @Test
    fun `a new window starts its own list, and the list is capped`() {
        var s = GuardAttemptWindow.record(null, t0, "deactivate_admin").state
        for (i in 0 until 20) s = GuardAttemptWindow.record(s, t0 + 1_000L + i, "screen_$i").state
        assertEquals(GuardAttemptWindow.MAX_SCREENS, s.screens.size)
        val fresh = GuardAttemptWindow.record(s, t0 + GuardAttemptWindow.WINDOW_MS, "space_setup")
        assertTrue(fresh.opensWindow)
        assertEquals(listOf("space_setup"), fresh.state.screens)
    }

    @Test
    fun `the aggregate body names every screen tried`() {
        val body = GuardAttemptWindow.body(3, listOf("deactivate_admin", "space_setup"), "Screen: device_admin in x")
        assertTrue(body, body.startsWith("3 attempts"))
        assertTrue(body, body.contains("Screens tried: device admin, second space setup."))
        assertEquals("one attempt keeps its detail", "Screen: space_setup in x", GuardAttemptWindow.body(1, listOf("space_setup"), "Screen: space_setup in x"))
    }

    @Test
    fun `the saved list comes back after a restart`() {
        val list = listOf("deactivate_admin", "space_setup")
        assertEquals(list, GuardAttemptWindow.decodeScreens(GuardAttemptWindow.encodeScreens(list)))
        assertEquals(emptyList<String>(), GuardAttemptWindow.decodeScreens(null))
        assertEquals(emptyList<String>(), GuardAttemptWindow.decodeScreens(""))
    }

    @Test
    fun `every screen kind has a label the parent can read`() {
        for (kind in TamperScreen.values().filter { it != TamperScreen.NONE }) {
            val label = GuardAttemptWindow.label(kind.name.lowercase())
            assertTrue("$kind -> $label", label.isNotBlank() && !label.contains('_'))
        }
        assertEquals("device admin", GuardAttemptWindow.label("deactivate_admin"))
        assertEquals("second space setup", GuardAttemptWindow.label("space_setup"))
    }

    @Test
    fun `the screen travels from the guard to the alert body`() {
        val service = sourceFile("app/src/main/java/com/familyshield/agent/services/AccessibilityMonitorService.kt")
        assertTrue(service.contains("GuardAttemptWindow.record(TamperState.guardAttemptWindow(this), now, screen.name.lowercase())"))
        assertTrue(service.contains("screens = attempt.state.screens,"))
        val worker = sourceFile("app/src/main/java/com/familyshield/agent/security/TamperAlertWorker.kt")
        assertTrue(worker.contains("KEY_SCREENS to GuardAttemptWindow.encodeScreens(screens)"))
        assertTrue(worker.contains("GuardAttemptWindow.decodeScreens(inputData.getString(KEY_SCREENS))"))
        assertTrue(worker.contains("GuardAttemptWindow.body(window.count, window.screens, detail)"))
        val state = sourceFile("app/src/main/java/com/familyshield/agent/security/TamperState.kt")
        assertTrue("saved with the window", state.contains(".putString(KEY_GUARD_WINDOW_SCREENS, GuardAttemptWindow.encodeScreens(window.screens))"))
        val load = state.substringAfter("fun guardAttemptWindow(", missingDelimiterValue = "").substringBefore("\n    }", missingDelimiterValue = "")
        assertTrue("and loaded back after a restart", load.contains("GuardAttemptWindow.decodeScreens(p.getString(KEY_GUARD_WINDOW_SCREENS, null))"))
        assertTrue("into the state it returns", load.contains("screens = screens"))
    }

    private fun sourceFile(relative: String): String {
        var dir: File? = File(System.getProperty("user.dir") ?: ".").absoluteFile
        while (dir != null) {
            val candidate = File(dir, relative)
            if (candidate.isFile) return candidate.readText()
            dir = dir.parentFile
        }
        throw AssertionError("could not find $relative from ${System.getProperty("user.dir")}")
    }
}
