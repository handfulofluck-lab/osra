package com.familyshield.agent.security

import java.io.File
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * #484 (Flip4, 1 Nov): after the tamper gate fired, the screen left behind varied across runs — the admin
 * list, Home, or the gate still holding — because the service sent an asynchronous GLOBAL_ACTION_BACK just
 * before opening the gate, and it landed on either window. One end state now: the gate always opens over the
 * guarded screen, and every way out of it without the PIN goes Home.
 *
 * Source-text rows, the `UnlinkedOverlayWiringTest` shape: this is the ordering of two framework calls inside
 * an accessibility service and an activity a plain JVM test cannot start. The phone row on #484 proves the end
 * state on the Flip4.
 *
 * Mutants: put `performGlobalAction(GLOBAL_ACTION_BACK)` back in the guard → [the guard opens the gate without
 * sending BACK first]; make "Go back", hardware back or the fifth wrong PIN `finish()` instead of `goHome()` →
 * [every way out without the PIN goes Home]; drop the HOME intent from `goHome` → [goHome lands on Home];
 * never clear `GuardGateState.showing`, or go back to a bare time check → [the debounce asks the policy];
 * drop `resizeableActivity="false"` from the gate → [the gate never shares the screen].
 */
class TamperGuardLandsHomeWiringTest {

    private val service = sourceFile("app/src/main/java/com/familyshield/agent/services/AccessibilityMonitorService.kt")
    private val gate = sourceFile("app/src/main/java/com/familyshield/agent/security/TamperGuardActivity.kt")
    private val manifest = sourceFile("app/src/main/AndroidManifest.xml")

    @Test
    fun `the guard opens the gate without sending BACK first`() {
        val guard = service.substringAfter("private fun guardProtectionScreens(", missingDelimiterValue = "")
            .substringBefore("\n    private ", missingDelimiterValue = "")
        assertTrue("guardProtectionScreens is where it was", guard.contains("TamperGuardActivity::class.java"))
        assertFalse("no BACK before the gate", guard.contains("GLOBAL_ACTION_BACK"))
        assertFalse("and no HOME, which would defer the gate's launch (#460)", guard.contains("GLOBAL_ACTION_HOME"))
    }

    @Test
    fun `every way out without the PIN goes Home`() {
        val back = gate.substringAfter("back.setOnClickListener", missingDelimiterValue = "").substringBefore("\n", missingDelimiterValue = "")
        assertTrue("Go back", back.contains("goHome()"))
        val hardware = gate.substringAfter("override fun onBackPressed()", missingDelimiterValue = "").substringBefore("}", missingDelimiterValue = "")
        assertTrue("hardware back", hardware.contains("goHome()"))
        assertTrue("the fifth wrong PIN", gate.contains("if (attempts >= MAX_ATTEMPTS) goHome()"))
        // The only finish() outside goHome is the verified-PIN path.
        val outsideGoHome = gate.substringBefore("private fun goHome()")
        assertEquals("one finish() before goHome, after a verified PIN", 1, Regex("""\bfinish\(\)""").findAll(outsideGoHome).count())
        val verified = gate.substringAfter("if (pinStore.verify(entered)) {").substringBefore("} else {")
        assertTrue(verified.contains("finish()"))
    }

    @Test
    fun `goHome lands on Home`() {
        val goHome = gate.substringAfter("private fun goHome()", missingDelimiterValue = "").substringBefore("\n    }", missingDelimiterValue = "")
        assertTrue(goHome.contains("Intent.ACTION_MAIN"))
        assertTrue(goHome.contains("Intent.CATEGORY_HOME"))
        assertTrue(goHome.contains("finish()"))
    }

    @Test
    fun `the debounce asks the policy, fed by the gate's own lifecycle`() {
        val guard = service.substringAfter("private fun guardProtectionScreens(", missingDelimiterValue = "")
            .substringBefore("\n    private ", missingDelimiterValue = "")
        assertTrue(
            "the service calls the pure rule with both flags",
            guard.contains("GuardDebouncePolicy.suppress(now, lastGuardMs, GuardGateState.showing, GuardGateState.resumedSince(lastGuardMs))"),
        )
        assertFalse("and no bare time check", guard.contains("now - lastGuardMs <"))
        val onResume = gate.substringAfter("override fun onResume()", missingDelimiterValue = "").substringBefore("\n    }", missingDelimiterValue = "")
        assertTrue("showing set on resume", onResume.contains("GuardGateState.showing = true"))
        assertTrue("and the resume time recorded", onResume.contains("GuardGateState.lastResumedMs = System.currentTimeMillis()"))
        val onPause = gate.substringAfter("override fun onPause()", missingDelimiterValue = "").substringBefore("\n    }", missingDelimiterValue = "")
        assertTrue("showing cleared on pause", onPause.contains("GuardGateState.showing = false"))
    }

    @Test
    fun `the gate never shares the screen, so it always pauses when it leaves the front`() {
        val entry = manifest.substringAfter("android:name=\".security.TamperGuardActivity\"", missingDelimiterValue = "")
            .substringBefore("/>", missingDelimiterValue = "")
        assertTrue("the gate's manifest entry is where it was", entry.contains("android:exported=\"false\""))
        assertTrue("not resizeable: no split screen, where both halves stay resumed", entry.contains("android:resizeableActivity=\"false\""))
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
