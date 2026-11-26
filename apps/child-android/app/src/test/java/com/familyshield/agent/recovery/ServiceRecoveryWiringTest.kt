package com.familyshield.agent.recovery

import java.io.File
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Issue #1085, Hydrogen's #1098 review: three facts `ServiceRecoveryPolicy` cannot read for itself, each of
 * which the reviewed tree read from the wrong source — and the policy rows stayed green, because a pure row
 * cannot see which reader the production code called.
 *
 * - `tunnelRunning` came from `VpnState.isEstablished`, a persisted flag cleared only in `onDestroy`, so
 *   after a kill it read `true` and the filter was never restarted. The in-process `tunnelMode` is `null` in
 *   a fresh process by construction.
 * - the location start checked fine-or-coarse only, skipping `LocationStartPolicy`, which is how a background
 *   worker starts `LocationService` without the background grant on API 29+ and crashes (#128/#132 again).
 * - the accessibility check hand-rolled the Settings split and never asked whether the service is bound,
 *   which is the exact state a MIUI kill leaves.
 *
 * Read as text, the technique `LocationServiceStartSitesTest` and `CapabilityWiringTest` use: a reference,
 * not the semantics. The semantics are `ServiceRecoveryPolicyTest` and `LocationStartPolicyTest`.
 *
 * Mutants: point any reader back at the old source and the matching row goes red.
 */
class ServiceRecoveryWiringTest {

    private val source = sourceFile("app/src/main/java/com/familyshield/agent/recovery/ServiceRecovery.kt")

    /**
     * The source with `//` comments removed. A scan that reads comments too fails on the note that explains the
     * finding (it names the old flag), which is a test that punishes documentation. Strings containing `//` are
     * not handled; this file has none, and a false positive would be obvious rather than silent.
     */
    private val code = source.lineSequence().joinToString(System.lineSeparator()) { line ->
        val cut = line.indexOf("//")
        if (cut < 0) line else line.substring(0, cut)
    }

    @Test
    fun `the tunnel fact is the in-process mode, not the persisted flag`() {
        assertTrue(
            "readState must ask the process, not SharedPreferences",
            source.contains("tunnelRunning = FilterVpnService.tunnelMode != null"),
        )
        assertFalse(
            "the persisted established flag stays true after a kill, which is what kept the filter down",
            code.contains("VpnState.isEstablished"),
        )
    }

    @Test
    fun `the location start goes through the background-start policy`() {
        assertTrue(source.contains("LocationStartPolicy.shouldStart("))
        assertTrue(
            "and asks for the background grant, which is what API 29+ actually requires",
            source.contains("Manifest.permission.ACCESS_BACKGROUND_LOCATION"),
        )
        assertTrue(source.contains("apiLevel = Build.VERSION.SDK_INT"))
    }

    @Test
    fun `the accessibility report separates switched off from not bound`() {
        assertTrue(
            "the shared parser handles the global switch and the pkg/.Class form",
            source.contains("AccessibilityOffPolicy.isEffectivelyEnabled("),
        )
        assertTrue(
            "and being bound is a different fact from being enabled",
            source.contains("accessibilityBound = AccessibilityMonitorService.isRunning"),
        )
    }

    @Test
    fun `a background lock launch is guarded and reorders instead of stacking`() {
        assertTrue(
            "Android 10+ drops the launch with neither the overlay app-op nor a bound service",
            source.contains("Settings.canDrawOverlays(context) || AccessibilityMonitorService.isRunning"),
        )
        assertTrue(source.contains("FLAG_ACTIVITY_REORDER_TO_FRONT"))
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
