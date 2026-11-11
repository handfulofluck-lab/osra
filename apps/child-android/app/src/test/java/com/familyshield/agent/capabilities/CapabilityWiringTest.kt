package com.familyshield.agent.capabilities

import java.io.File
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * ADR-0034 A2, the two wiring facts the pure rows cannot see (Claude's #535 review, faults f8 and f9).
 *
 * - The fingerprint is what the server **accepted**, so it is recorded only after the POST returns: recorded
 *   before it, a failed upload would be remembered as covered and the change would never be retried.
 * - `pair/claim` carries the report, so a new phone is described from its first minute.
 */
class CapabilityWiringTest {

    private val reporter = sourceFile("app/src/main/java/com/familyshield/agent/telemetry/UsageReporter.kt")
    private val pairing = sourceFile("app/src/main/java/com/familyshield/agent/setup/PairingActivity.kt")

    @Test
    fun `the change-triggered upload records the fingerprint only after the POST succeeds`() {
        val start = reporter.indexOf("suspend fun reportCapabilitiesIfChanged()")
        assertTrue("the change-triggered upload exists", start >= 0)
        val end = reporter.indexOf("suspend fun ", start + 1).let { if (it < 0) reporter.length else it }
        val body = reporter.substring(start, end)
        val post = body.indexOf("api.postTelemetry(")
        val recordCall = "settings.recordReportedCapabilities(fingerprint)"
        val record = body.indexOf(recordCall)
        val catch = body.indexOf("catch (e: Exception)")
        assertTrue("both the POST and the record are in it", post >= 0 && record >= 0 && catch >= 0)
        assertTrue("the record follows the POST, inside the try", record in (post + 1) until catch)
        assertTrue("and there is exactly one", body.indexOf("recordReportedCapabilities(", record + recordCall.length) < 0)
    }

    @Test
    fun `the pairing claim carries the capability report`() {
        assertTrue(
            "a claim without the report leaves a new phone undescribed until its first periodic upload",
            pairing.contains("""put("capabilities", JSONObject(it))"""),
        )
    }

    @Test
    fun `every other upload that carries the report records it, and only after its POST`() {
        // #535 review point 5 (fault f14): the periodic upload and the location-grant report carry the report
        // too, so each records the fingerprint once its POST has returned, or the next resume sends it again.
        for (signature in listOf("suspend fun aggregateAndUpload()", "suspend fun reportLocationGrantIfChanged()")) {
            val body = functionBody(reporter, signature)
            val post = body.indexOf("api.postTelemetry(")
            val record = body.indexOf("recordCapabilities(report)")
            assertTrue("$signature posts and records the report", post >= 0 && record >= 0)
            assertTrue("$signature records only after the POST", record > post)
        }
    }

    @Test
    fun `a pairing claim counts as reported only once the parent allows it`() {
        // #535 review point 5 (fault f15): the server stores the report at Allow, so a refused or abandoned
        // claim must leave no fingerprint behind.
        val approved = pairing.indexOf("PairingApproval.PollStep.APPROVED ->")
        val record = pairing.indexOf("recordReportedCapabilities(")
        assertTrue("the Allow branch exists", approved >= 0)
        assertTrue("the fingerprint is recorded inside it", record > approved)
        assertTrue("and nowhere else", pairing.indexOf("recordReportedCapabilities(", record + 1) < 0)
    }

    private fun functionBody(source: String, signature: String): String {
        val start = source.indexOf(signature)
        assertTrue("$signature exists", start >= 0)
        val end = source.indexOf("suspend fun ", start + 1).let { if (it < 0) source.length else it }
        return source.substring(start, end)
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
