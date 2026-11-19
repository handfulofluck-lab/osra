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

    private companion object {
        /** The line after the cover path, so a slice cannot end above the read it is looking for. */
        const val NEXT_FUNCTION_ANCHOR = "\n    private fun removeGuardCover("
    }

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
        // The cover path reads it the same way, still gated on the pane being the active one. Sliced to the function
        // (Hydrogen's note): `service.contains` was satisfied by the guard's own occurrence, so deleting the cover
        // path's read left this row green.
        // Bounded by the next function rather than a closing brace: the cover path spans 70 lines with plenty of
        // inner braces, so a closing-brace slice could end above the read it is meant to find.
        val cover = service.substringAfter("private fun coverSharedProtectionScreens(", missingDelimiterValue = "")
            .substringBefore(NEXT_FUNCTION_ANCHOR, missingDelimiterValue = "")
        assertTrue(
            "and the multi-window path does too",
            cover.contains("pkg?.let { lastClassByPkg[it] }"),
        )
    }

    /**
     * Claude's item 1 on #817: reverting the service to pass the event's package into the latches left every test
     * green, because the planted fault only moved the helper. This row drives the wiring: the service computes
     * `latchPackage(pkg, pkgOfEvent)` once and hands that to **both** latches.
     *
     * Mutant: pass `pkgOfEvent` to either latch → this row goes red.
     */
    @Test
    fun `the service latches on the package it chose, not on the raw event package`() {
        assertTrue(
            "the choice is made once, through the helper",
            guard.contains("AccessibilityOffPolicy.latchPackage(pkg, pkgOfEvent)"),
        )
        val latchCalls = guard.substringAfter("val latchPkg =").substringBefore("if (!settings.isPairedSync())")
        assertTrue(
            "and both latches read it",
            latchCalls.contains("packageName = latchPkg,"),
        )
        assertFalse(
            "neither latch reads the event's package directly",
            latchCalls.contains("packageName = pkgOfEvent,"),
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
