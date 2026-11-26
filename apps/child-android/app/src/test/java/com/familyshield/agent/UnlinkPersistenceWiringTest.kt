package com.familyshield.agent

import java.io.File
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Issue #1162, from Ahmed's sign-off on #1161: the persistence existed in `UnlinkPolicy` but the provider
 * still built it bare, so a process death restarted the confirmation clock. Safe direction, and not what the
 * class was written to do.
 *
 * Read as text, the technique the other wiring tests use; the semantics are `UnlinkPolicyTest`.
 *
 * Mutants: `UnlinkPolicy()` with no arguments (row 2), or passing the value without the callback (row 1).
 */
class UnlinkPersistenceWiringTest {

    private val module = sourceFile("app/src/main/java/com/familyshield/agent/di/AppModule.kt")

    @Test
    fun `the policy is built from the stored answer and writes it back`() {
        assertTrue(
            "the stored first answer must reach the policy, or a restart restarts the clock",
            module.contains("persistedFirstRevokedAtMs = settings.firstRevokedAtMsSync()"),
        )
        assertTrue(
            "and every answer must be written back through the callback",
            module.contains("persist = { ms -> scope.launch { settings.saveFirstRevokedAtMs(ms) } }"),
        )
    }

    @Test
    fun `the provider does not construct the policy bare`() {
        assertFalse(
            "UnlinkPolicy() with no store is the bug Ahmed caught on #1161",
            module.contains("UnlinkPolicy()"),
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
