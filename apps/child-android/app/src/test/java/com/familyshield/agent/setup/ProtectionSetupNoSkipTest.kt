package com.familyshield.agent.setup

import java.io.File
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Issue #1175: Device Admin is a required grant; `PairingActivity.showProtectionSetup()` must not
 * offer an unconditional Skip button that advances to `showComplete()` while device admin is
 * inactive.
 */
class ProtectionSetupNoSkipTest {

    private val source by lazy {
        sourceFile("app/src/main/java/com/familyshield/agent/setup/PairingActivity.kt").readText()
    }

    /**
     * Mutant: re-add a Skip button calling `showComplete()` inside the `replaceWith { ... }` block
     * of `showProtectionSetup()`, and both assertions fail.
     */
    @Test
    fun `showProtectionSetup cannot reach showComplete while device admin is inactive`() {
        val fnBody = source
            .substringAfter("private fun showProtectionSetup() {")
            .substringBefore("\n    }")

        assertTrue(
            "showProtectionSetup() must still check deviceAdmin.isAdminActive() before completing",
            fnBody.contains("if (deviceAdmin.isAdminActive())"),
        )

        val inactiveUi = fnBody.substringAfter("replaceWith {")
        assertTrue(
            "showProtectionSetup() must offer the Device Admin activation button when admin is inactive",
            inactiveUi.contains("setup_activate_admin") && inactiveUi.contains("launchAdminSheet()"),
        )
        assertFalse(
            "showProtectionSetup() must not offer setup_skip when device admin is inactive (#1175)",
            inactiveUi.contains("setup_skip"),
        )
        assertFalse(
            "showProtectionSetup() must not call showComplete() when device admin is inactive (#1175)",
            inactiveUi.contains("showComplete("),
        )
    }

    /**
     * Mutant: allow `SetupResumePolicy.stageAfterPermissionReturn` to advance from
     * `PROTECTION_SETUP` to `COMPLETE` when `isAdminActive` is false, and this fails.
     */
    @Test
    fun `SetupResumePolicy keeps PROTECTION_SETUP and never reaches COMPLETE while admin is inactive`() {
        val next = SetupResumePolicy.stageAfterPermissionReturn(
            pinConfigured = true,
            currentStage = GuidedStage.PROTECTION_SETUP,
            isAdminActive = false,
            staleKnox = false,
            canComplete = true,
            forceChecklist = false,
        )
        assertEquals(GuidedStage.PROTECTION_SETUP, next)
    }

    private fun sourceFile(relative: String): File {
        var dir: File? = File(System.getProperty("user.dir") ?: ".").absoluteFile
        while (dir != null) {
            val candidate = File(dir, relative)
            if (candidate.isFile) return candidate
            dir = dir.parentFile
        }
        throw AssertionError("could not find $relative from ${System.getProperty("user.dir")}")
    }
}
