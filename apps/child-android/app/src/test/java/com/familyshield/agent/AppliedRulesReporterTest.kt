package com.familyshield.agent

import com.familyshield.agent.telemetry.AppliedRulesReporter
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * #865 second half: the applied rules version reaches the server when it moves, not at the next tick.
 *
 * Mutants: drop the `current == null` guard and [a phone that never applied a ruleset says nothing] goes red;
 * `upload` before `recordReported` and [a failed upload is retried] goes red; compare against the applied
 * version instead of the reported one and [only a change is sent] goes red on the second call.
 */
class AppliedRulesReporterTest {

    private class FakeServer {
        var reported: Int? = null
        val uploads = mutableListOf<Int>()
        var failNext = false

        val reporter = AppliedRulesReporter(
            lastReported = { reported },
            recordReported = { reported = it },
            upload = { version ->
                if (failNext) {
                    failNext = false
                    throw IllegalStateException("network down")
                }
                uploads += version
            },
        )
    }

    @Test
    fun `a new version is uploaded once and remembered`() = runBlocking {
        val server = FakeServer()
        assertTrue(server.reporter.reportIfChanged(15))
        assertEquals(listOf(15), server.uploads)
        assertEquals(15, server.reported)

        // The periodic tick asks again: the server already knows, so nothing is sent.
        assertFalse(server.reporter.reportIfChanged(15))
        assertEquals(listOf(15), server.uploads)
    }

    @Test
    fun `a phone that never applied a ruleset says nothing`() = runBlocking {
        val server = FakeServer()
        // Reporting 0 (or nothing) would be a claim the phone cannot make.
        assertFalse(server.reporter.reportIfChanged(null))
        assertTrue(server.uploads.isEmpty())
        assertEquals(null, server.reported)
    }

    @Test
    fun `a failed upload is retried rather than remembered as done`() = runBlocking {
        val server = FakeServer()
        server.failNext = true
        var threw = false
        try {
            server.reporter.reportIfChanged(16)
        } catch (e: IllegalStateException) {
            threw = true
        }
        assertTrue("the failure must reach the caller, which logs and retries", threw)
        // The mutant records before uploading: the retry would then be skipped and the server would keep 15.
        assertEquals(null, server.reported)

        assertTrue(server.reporter.reportIfChanged(16))
        assertEquals(listOf(16), server.uploads)
        assertEquals(16, server.reported)
    }
}
