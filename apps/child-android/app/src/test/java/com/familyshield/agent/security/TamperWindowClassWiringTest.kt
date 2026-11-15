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
 * osra-security#29 (#817, Antigravity's Flip4 pass): "the last state change's class" was one global pair, so the
 * search keyboard's state change erased Settings' class and the access pages lost their identity mid-search. The
 * class is now kept per package ([lastClassByPkg]) and read back by the foreground package. The rows follow that:
 * they assert the per-package map is written on a state change and read by package at both classify sites, and that
 * no global pair is back.
 *
 * Mutants: read `lastClassByPkg` from the event's package instead of the foreground one → [the class is read for the
 * package in front] goes red; take the class from every event type → [the class is kept from window-state changes
 * only] goes red.
 */
class TamperWindowClassWiringTest {

    private val service = sourceFile("app/src/main/java/com/familyshield/agent/services/AccessibilityMonitorService.kt")
    private val guard = service.substringAfter("private fun guardProtectionScreens(").substringBefore("performGlobalAction(")

    @Test
    fun `the class is kept from window-state changes only`() {
        // missingDelimiterValue = "": without it, a guard with no state-change test would hand back the whole
        // guard here, which still contains the assignment, and the row would pass.
        val kept = guard.substringAfter(
            "if (event.eventType == AccessibilityEvent.TYPE_WINDOW_STATE_CHANGED) {",
            missingDelimiterValue = "",
        ).substringBefore("}")
        assertTrue(
            "the class is kept per package, from a state change",
            kept.contains("lastClassByPkg[") && kept.contains("event.className?.toString()"),
        )
        assertFalse(
            "the single global pair that the keyboard used to overwrite is not back",
            guard.contains("lastWindowClass = ") || guard.contains("lastWindowClassPkg = "),
        )
    }

    @Test
    fun `the class is read for the package in front`() {
        assertTrue(
            "the guard passes the foreground package's own class, so an IME state change cannot erase it",
            guard.contains("windowClass = pkg?.let { lastClassByPkg[it] }"),
        )
        // The cover path reads it the same way, still gated on the pane being the active one.
        assertTrue(
            "and the multi-window path does too",
            service.contains("pkg?.let { lastClassByPkg[it] }"),
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
