package com.familyshield.agent.security

import java.io.File
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * osra-security#7: the wiring of the guard's cover, which a JVM test cannot start (an accessibility service and
 * a WindowManager overlay). [GuardCoverPolicyTest] holds the decision; these rows hold that the service asks it,
 * on the events that carry a window change, over every visible window, and draws the answer.
 *
 * Faults each row catches: drop `typeWindowsChanged` from the config, or handle it after the package-name return
 * (it has no package) → [window changes reach the cover]; read only `rootInActiveWindow` → [every visible
 * application window is judged]; never call `guardCover.update` or never launch the gate when the cover goes up
 * → [the cover is drawn and the gate opens once]; leave the cover on screen when the service stops →
 * [the cover goes with the service]; anchor physical bounds with relative gravity →
 * [physical window bounds stay anchored to the physical left in RTL].
 */
class GuardCoverWiringTest {

    private val service = sourceFile("app/src/main/java/com/familyshield/agent/services/AccessibilityMonitorService.kt")
    private val config = sourceFile("app/src/main/res/xml/accessibility_config.xml")
    private val overlay = sourceFile("app/src/main/java/com/familyshield/agent/services/PipCoverOverlay.kt")
    private val cover = service.substringAfter("private fun coverSharedProtectionScreens()", missingDelimiterValue = "")
        .substringBefore("private fun removeGuardCover()", missingDelimiterValue = "")

    @Test
    fun `window changes reach the cover`() {
        assertTrue("the service asks for window changes", config.contains("typeWindowsChanged"))
        assertTrue("and keeps the interactive-windows flag", config.contains("flagRetrieveInteractiveWindows"))
        val entry = service.substringAfter("override fun onAccessibilityEvent(", missingDelimiterValue = "")
        val handled = entry.indexOf("AccessibilityEvent.TYPE_WINDOWS_CHANGED")
        val pkgReturn = entry.indexOf("val eventPkg = event?.packageName?.toString() ?: return")
        assertTrue("TYPE_WINDOWS_CHANGED is handled", handled >= 0 && pkgReturn >= 0)
        assertTrue("before the package-name return, which it would never pass", handled < pkgReturn)
        assertTrue(
            "it runs the cover",
            entry.substring(handled, pkgReturn).contains("coverSharedProtectionScreens()"),
        )
        val ownReturn = entry.indexOf("if (eventPkg == packageName)")
        val stateCall = entry.indexOf("coverSharedProtectionScreens()", pkgReturn)
        assertTrue("state changes run it too, before our own gate's events return", stateCall in (pkgReturn + 1) until ownReturn)
    }

    @Test
    fun `every visible application window is judged`() {
        assertTrue("the cover is where it was", cover.isNotEmpty())
        assertTrue("it reads the window list", cover.contains("runCatching { windows }"))
        assertTrue("application windows", cover.contains("AccessibilityWindowInfo.TYPE_APPLICATION"))
        assertTrue("each window's own root", cover.contains("window.root"))
        assertFalse("not only the active window: in split screen the other half has focus", cover.contains("rootInActiveWindow"))
        assertTrue("classified with the shared policy", cover.contains("TamperScreenPolicy.classify("))
        assertTrue("with each window's bounds", cover.contains("window.getBoundsInScreen(r)"))
    }

    @Test
    fun `the cover is drawn and the gate opens once`() {
        assertTrue(cover.contains("GuardCoverPolicy.cover(found, guardActive)"))
        assertTrue(cover.contains("guardCover.update(next)"))
        val stepIn = cover.substringAfter("if (GuardCoverPolicy.stepIn(previous, next)) {", missingDelimiterValue = "")
        assertTrue("the gate opens and the parent is told", stepIn.contains("stepIn(firstScreen, firstPkg, now)"))
        assertTrue("grace and no PIN take the cover away", cover.contains("if (!guardActive) return removeGuardCover()"))
        // The view is above every application window and takes touches, never focus.
        assertTrue(overlay.contains("TYPE_ACCESSIBILITY_OVERLAY"))
        assertTrue(overlay.contains("FLAG_NOT_FOCUSABLE"))
        assertFalse(overlay.contains("FLAG_NOT_TOUCHABLE"))
    }

    @Test
    fun `the cover goes with the service`() {
        val onDestroy = service.substringAfter("override fun onDestroy()", missingDelimiterValue = "").substringBefore("\n    }", missingDelimiterValue = "")
        assertTrue(onDestroy.contains("guardCover.remove()"))
    }

    @Test
    fun `physical window bounds stay anchored to the physical left in RTL`() {
        assertTrue("the overlay is positioned from WindowBounds.left", overlay.contains("x = target.left"))
        assertTrue(
            "a physical x coordinate must not use Gravity.START, whose origin flips in RTL (#709)",
            overlay.contains("gravity = Gravity.TOP or Gravity.LEFT"),
        )
    }

    private fun sourceFile(relative: String): String {
        var dir: File? = File(System.getProperty("user.dir")).absoluteFile
        while (dir != null) {
            val candidate = File(dir, relative)
            if (candidate.isFile) return candidate.readText()
            dir = dir.parentFile
        }
        throw AssertionError("could not find $relative from ${System.getProperty("user.dir")}")
    }
}
