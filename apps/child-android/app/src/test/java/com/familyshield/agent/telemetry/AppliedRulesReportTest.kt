package com.familyshield.agent.telemetry

import java.io.File
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Karim 23 Nov test: the Parent app showed a rule change as "pending on the phone" long after the phone
 * applied it, because the applied version only rode the periodic 15-minute upload.
 *
 * The decision is [AppliedRulesReportPolicy] (pure JVM cases below). `UsageReporter` needs Android, Room and
 * an injected service and cannot run in this suite, so the wiring is pinned from the source, as in
 * [UsageReporterConsentWiringTest]. What a green run does not mean: that the banner clears on a real phone.
 * That row is the Flip4 operator's.
 */
class AppliedRulesReportTest {

    @Test
    fun `a newly applied version is reported`() {
        assertTrue(AppliedRulesReportPolicy.shouldReport(applied = 19, lastReported = 18))
        assertTrue(AppliedRulesReportPolicy.shouldReport(applied = 1, lastReported = null))
    }

    @Test
    fun `nothing is reported before any rules are applied or when the server already has it`() {
        assertFalse(AppliedRulesReportPolicy.shouldReport(applied = null, lastReported = null))
        assertFalse(AppliedRulesReportPolicy.shouldReport(applied = 19, lastReported = 19))
    }

    @Test
    fun `an older upload finishing last does not roll the marker back`() {
        // The immediate report of 4 succeeds first, then the periodic upload that carried 3 succeeds.
        val afterImmediate = AppliedRulesReportPolicy.acknowledged(current = 3, version = 4)
        assertEquals(4, AppliedRulesReportPolicy.acknowledged(current = afterImmediate, version = 3))
        assertEquals(4, AppliedRulesReportPolicy.acknowledged(current = 4, version = 4))
        // A cleared marker (re-pair) takes whatever version is acknowledged first.
        assertEquals(2, AppliedRulesReportPolicy.acknowledged(current = null, version = 2))
    }

    @Test
    fun `the stored marker goes through the monotonic rule in one edit`() {
        val settings = sourceFile("app/src/main/java/com/familyshield/agent/data/AgentSettings.kt")
        val body = settings.substringAfter("suspend fun recordReportedAppliedRulesVersion(").substringBefore("\n    }\n")
        val edit = body.indexOf("store.edit")
        val read = body.indexOf("it[KEY_REPORTED_APPLIED_RULES_VERSION]?.toIntOrNull()")
        val merge = body.indexOf("AppliedRulesReportPolicy.acknowledged(")
        assertTrue("reads the current marker inside the edit", edit in 0 until read)
        assertTrue("and writes it through acknowledged()", read in 0 until merge)
    }

    private val reporter = sourceFile("app/src/main/java/com/familyshield/agent/telemetry/UsageReporter.kt")

    @Test
    fun `every successful rules refresh triggers the immediate report`() {
        val init = reporter.substringAfter("init {").substringBefore("\n    }")
        assertTrue(
            "UsageReporter must listen for rule refreshes and report the applied version",
            init.contains("rules.addRulesChangedListener") && init.contains("reportAppliedRulesIfChanged()"),
        )
    }

    @Test
    fun `the immediate report respects consent and records only after a successful post`() {
        val body = reporter.substringAfter("suspend fun reportAppliedRulesIfChanged()").substringBefore("\n    }\n")
        val pause = body.indexOf("if (consent.isPaused()) return")
        val post = body.indexOf("api.postTelemetry")
        val record = body.indexOf("settings.recordReportedAppliedRulesVersion")
        assertTrue("reads the consent flag before posting", pause in 0 until post)
        assertTrue("records the version only after the post", post in 0 until record)
    }

    @Test
    fun `the periodic upload also counts as reporting the applied version`() {
        val periodic = reporter.substringAfter("val appliedRules = settings.appliedRulesVersion()").substringBefore("dao.deleteOlderThan")
        assertTrue(periodic.contains("settings.recordReportedAppliedRulesVersion"))
    }

    private fun sourceFile(relative: String): String {
        var dir: File? = File(System.getProperty("user.dir")).absoluteFile
        while (dir != null) {
            val candidate = File(dir, relative)
            if (candidate.isFile) return candidate.readText()
            dir = dir.parentFile
        }
        error("source file not found: $relative")
    }
}
