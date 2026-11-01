package com.familyshield.agent.security

import java.io.File
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * osra-security#5: `TamperScreenPolicy.classify` treats the device-admin sheet as a protection screen only while
 * our admin is active, so the parent's activation sheet during setup is never guarded. The policy rows pin the
 * rule; this row pins that the service passes the live answer, not a constant. Source-text row, the
 * `TamperWindowClassWiringTest` shape: the service cannot be started on the JVM.
 *
 * Mutants: `ourAdminActive = true` (guards the activation sheet) or `= false` (never guards deactivation) → red.
 */
class TamperAdminActiveWiringTest {

    private val service = sourceFile("app/src/main/java/com/familyshield/agent/services/AccessibilityMonitorService.kt")
    private val guard = service.substringAfter("private fun guardProtectionScreens(", missingDelimiterValue = "")
        .substringBefore("performGlobalAction(")

    @Test
    fun `the guard asks the device admin whether our admin is active`() {
        assertTrue("the guard must exist", guard.isNotEmpty())
        assertTrue(
            "classify is given the live admin state, never a constant",
            guard.contains("ourAdminActive = deviceAdmin.isAdminActive(),"),
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
