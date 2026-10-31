package com.familyshield.agent.security

import java.io.File
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * #507 review: `TamperScreenPolicy.classify` takes the window's class, and the service decides which class
 * that is. A content change carries a view class, not the activity, so the service keeps the class of the last
 * TYPE_WINDOW_STATE_CHANGED and passes it only while that same package is in front. Source-text rows, the
 * `UnlinkedRefreshWiringTest` shape: the service cannot be started on the JVM.
 *
 * Mutants: drop the package check from the `windowClass =` argument → [the kept class is passed only for
 * the same package] goes red; take the class from every event type → [the class is kept from window-state
 * changes only] goes red.
 */
class TamperWindowClassWiringTest {

    private val service = sourceFile("app/src/main/java/com/familyshield/agent/services/AccessibilityMonitorService.kt")
    private val guard = service.substringAfter("private fun guardProtectionScreens(").substringBefore("performGlobalAction(")

    @Test
    fun `the class is kept from window-state changes only`() {
        val kept = guard.substringAfter("if (event.eventType == AccessibilityEvent.TYPE_WINDOW_STATE_CHANGED) {")
            .substringBefore("}")
        assertTrue("the class comes from a state change", kept.contains("lastWindowClass = event.className?.toString()"))
        assertTrue("with its package", kept.contains("lastWindowClassPkg = event.packageName?.toString()"))
        assertFalse(
            "nowhere else in the guard is the class overwritten",
            guard.substringAfter(kept).contains("lastWindowClass = "),
        )
    }

    @Test
    fun `the kept class is passed only for the same package`() {
        assertTrue(
            "a class from another package must not classify this window",
            guard.contains("windowClass = lastWindowClass.takeIf { lastWindowClassPkg != null && lastWindowClassPkg == pkg }"),
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
