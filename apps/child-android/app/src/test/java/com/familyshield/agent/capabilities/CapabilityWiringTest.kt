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
        val record = body.indexOf("settings.recordReportedCapabilities(fingerprint)")
        val catch = body.indexOf("catch (e: Exception)")
        assertTrue("both the POST and the record are in it", post >= 0 && record >= 0 && catch >= 0)
        assertTrue("the record follows the POST, inside the try", record in (post + 1) until catch)
        assertTrue("and there is exactly one", body.indexOf("recordReportedCapabilities(", record + 1) < 0)
    }

    @Test
    fun `the pairing claim carries the capability report`() {
        assertTrue(
            "a claim without the report leaves a new phone undescribed until its first periodic upload",
            pairing.contains("""put("capabilities", JSONObject(it))"""),
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
