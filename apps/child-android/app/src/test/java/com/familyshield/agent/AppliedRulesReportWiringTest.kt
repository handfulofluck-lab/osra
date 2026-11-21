package com.familyshield.agent

import java.io.File
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * #865 second half: the wiring, pinned where a refactor would quietly drop it.
 *
 * The behaviour is the pure [AppliedRulesReporter] and the server's own rows; this file is about the three
 * places that have to line up for it to happen at all.
 */
class AppliedRulesReportWiringTest {

    /** Same walker as the other wiring tests: Gradle's working directory is the module, not the repo root. */
    private fun source(relative: String): String {
        var dir: File? = File(System.getProperty("user.dir")).absoluteFile
        while (dir != null) {
            val candidate = File(dir, relative)
            if (candidate.isFile) return candidate.readText()
            dir = dir.parentFile
        }
        throw AssertionError("could not find $relative from ${System.getProperty("user.dir")}")
    }

    @Test
    fun `the version is handed over only after it was stored`() {
        val repository = source("app/src/main/java/com/familyshield/agent/data/RuleRepository.kt")

        // Guarded by the same persisted branch: a failed write must not announce a version.
        val save = repository.indexOf("settings.saveAppliedRulesVersion(")
        val fire = repository.indexOf("rulesAppliedListeners.forEach")
        assertTrue("the listener must fire after the save", save in 0 until fire)
        // The report sits inside the `if (persisted) {` block that follows enforcement being told.
        val guard = repository.lastIndexOf("if (persisted) {", fire)
        assertTrue("the report is guarded by the write having succeeded", guard in 0 until fire)
        // Mutant: move the forEach out of `onSuccess` and this row's ordering check is the one that fails.
        assertEquals(1, Regex("""rulesAppliedListeners\.forEach""").findAll(repository).count())
    }

    /// Claude's review on #879: the report used to run inline, before enforcement was told, so on a dead
    /// network the phone kept enforcing the old rules while telling the parent the new ones were applied.
    @Test
    fun `enforcement hears first, and the report never blocks the refresh`() {
        val repository = source("app/src/main/java/com/familyshield/agent/data/RuleRepository.kt")
        val enforcement = repository.indexOf("rulesChangedListeners.forEach")
        val report = repository.indexOf("rulesAppliedListeners.forEach")
        assertTrue("both must be present", enforcement >= 0 && report >= 0)
        // Mutant: fire the report before the enforcement listeners and this ordering check fails.
        assertTrue("enforcement is told before the server", enforcement < report)
        // And the report is launched, not awaited: a slow upload must not hold up this refresh.
        val launch = repository.lastIndexOf("appScope.launch", report)
        assertTrue("the report runs on the agent's own scope", launch in 0 until report)
    }

    @Test
    fun `the reporter is registered and posts the version it was handed`() {
        val reporter = source("app/src/main/java/com/familyshield/agent/telemetry/UsageReporter.kt")

        assertTrue(reporter.contains("rules.addRulesAppliedListener { reportAppliedRulesIfChanged() }"))
        // The upload carries the version, not a re-read that could race a newer apply.
        assertTrue(reporter.contains("appliedRulesVersion = version"))
        // ADR-0008 §3: nothing goes out while consent is withdrawn.
        assertTrue(reporter.contains("if (consent.isPaused()) return"))
        // The accepted version is recorded after the upload returns, inside the reporter's upload lambda.
        assertTrue(reporter.contains("recordReported = { settings.recordReportedAppliedRulesVersion(it) }"))
    }

    @Test
    fun `the accepted version is tracked apart from the applied one`() {
        val settings = source("app/src/main/java/com/familyshield/agent/data/AgentSettings.kt")

        // Two keys, two meanings: "what the phone holds" and "what the server acknowledged". Collapsing them
        // into one would make a failed upload permanently silent.
        assertTrue(settings.contains("stringPreferencesKey(\"applied_rules_version\")"))
        assertTrue(settings.contains("stringPreferencesKey(\"reported_applied_rules_version\")"))
        assertTrue(settings.contains("suspend fun reportedAppliedRulesVersion(): Int?"))
        assertTrue(settings.contains("suspend fun recordReportedAppliedRulesVersion(version: Int)"))
    }
}
