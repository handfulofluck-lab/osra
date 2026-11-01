package com.familyshield.agent.telemetry

import java.io.File
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * osra-security#6 item 1 (withdrawn): the parent's usage report and the daily limit count a cloned app's
 * time because **one** `recordForeground` call feeds both — the limit's counters and the Room rows the
 * report is built from. If that call were split, the two would drift apart silently: time enforced but
 * never shown, or shown but never enforced.
 *
 * Source-text rows, the `UnlinkedOverlayWiringTest` shape: the point is that both sinks hang off the same
 * call, which a plain JVM test cannot construct `UsageReporter` to show.
 *
 * Mutants: move the Room insert out of `recordForeground` → [one call feeds both]; drop
 * `rules.onForegroundEvent` from it → same row; call `recordForeground` from a second place in the
 * accessibility service → [the accessibility service calls it once per event].
 */
class UsageReportCountersWiringTest {

    private val reporter = sourceFile("app/src/main/java/com/familyshield/agent/telemetry/UsageReporter.kt")
    private val service = sourceFile("app/src/main/java/com/familyshield/agent/services/AccessibilityMonitorService.kt")

    @Test
    fun `one recordForeground call feeds both the limit's counters and the report's rows`() {
        val body = reporter.substringAfter("fun recordForeground(pkg: String, ts: Long) {", missingDelimiterValue = "")
            .substringBefore("\n    fun ", missingDelimiterValue = "")
            .substringBefore("\n    /**", missingDelimiterValue = "")
        assertTrue("recordForeground is where it was", body.isNotEmpty())
        assertTrue("it feeds the limit's counters", body.contains("rules.onForegroundEvent(pkg, ts)"))
        assertTrue(
            "and writes the Room row the report is built from",
            body.contains("usageEventDao().insert(UsageEventEntity(packageId = pkg, timestamp = ts))"),
        )
    }

    @Test
    fun `the report is built from those rows`() {
        assertTrue(reporter.contains("computePerAppMinutes(events,"))
    }

    @Test
    fun `the accessibility service calls it once per event, for the window in front`() {
        assertEquals("one call site", 1, Regex("""usage\.recordForeground\(""").findAll(service).count())
        assertTrue(service.contains("usage.recordForeground(foreground, System.currentTimeMillis())"))
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
