package com.familyshield.agent

import java.io.File
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Issue #475, agent half: the version the phone reports is the one it **saved and applied**, never the one
 * it fetched.
 *
 * The ordering is the whole feature. A version stored at fetch time would tell the parent the phone has a
 * change while the previous rules are still in force — the parent's line would clear on exactly the state it
 * exists to warn about. So: `saveRulesJson` first, and the version only if that write succeeded.
 *
 * Mutants: move `saveAppliedRulesVersion` above the `saveRulesJson` call, or drop the `if (persisted)`
 * guard — each turns [the applied version moves only after the rules are persisted] red. Drop
 * `appliedRulesVersion` from the telemetry DTO and [every telemetry upload carries it] goes red.
 */
class AppliedRulesVersionWiringTest {

    private val repository = sourceFile("app/src/main/java/com/familyshield/agent/data/RuleRepository.kt")
    private val reporter = sourceFile("app/src/main/java/com/familyshield/agent/telemetry/UsageReporter.kt")
    private val settings = sourceFile("app/src/main/java/com/familyshield/agent/data/AgentSettings.kt")
    private val dto = sourceFile("app/src/main/java/com/familyshield/agent/network/dto/PayloadDtos.kt")

    @Test
    fun `the applied version moves only after the rules are persisted`() {
        val saveRules = repository.indexOf("settings.saveRulesJson(")
        val saveVersion = repository.indexOf("settings.saveAppliedRulesVersion(")
        assertTrue("both must be present", saveRules > 0 && saveVersion > 0)
        assertTrue("the version must not be stored before the rules are", saveVersion > saveRules)
        assertTrue(
            "and only when the rules were actually written",
            repository.contains("if (persisted) runCatching { settings.saveAppliedRulesVersion(updated.rulesVersion) }"),
        )
        assertEquals(
            "one writer, so there is no second path to drift",
            1,
            Regex("""saveAppliedRulesVersion\(""").findAll(repository).count(),
        )
    }

    @Test
    fun `the stored version is the one the server sent with the ruleset`() {
        assertTrue(repository.contains("updated.rulesVersion"))
        assertTrue(settings.contains("suspend fun appliedRulesVersion(): Int?"))
        // Null until a ruleset has been applied: a fresh install has not reported anything.
        assertTrue(settings.contains(".toIntOrNull()"))
    }

    @Test
    fun `every telemetry upload carries it`() {
        assertTrue(dto.contains("val appliedRulesVersion: Int? = null"))
        assertEquals(
            "both upload paths — the periodic one and the grant report — send it",
            2,
            Regex("appliedRulesVersion = ").findAll(reporter).count(),
        )
        assertFalse(
            "a constant would report the same version forever",
            reporter.contains("appliedRulesVersion = 1"),
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
