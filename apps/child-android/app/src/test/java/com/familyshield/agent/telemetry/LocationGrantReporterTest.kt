package com.familyshield.agent.telemetry

import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Issue #221 (D1 follow-up): the grant is uploaded as soon as it changes, not at the next 15-minute
 * telemetry tick — otherwise a child who just granted "Allow all the time" is still refused a Locate
 * for up to fifteen minutes (measured on the Flip4 by Claude, review of #228).
 *
 * The upload itself needs Android, so the rule is tested here through the same injected-lambda shape
 * the reporter uses: report on a change, stay silent otherwise, and never record a value the server
 * did not accept. The caller's wiring is three lines in `UsageReporter.reportLocationGrantIfChanged`.
 */
class LocationGrantReporterTest {

    private class Recorder(startReported: String? = null) {
        var reported: String? = startReported
        val uploads = mutableListOf<String>()

        fun reporter(failUpload: Boolean = false) = LocationGrantReporter(
            lastReported = { reported },
            recordReported = { reported = it },
            upload = { grant ->
                if (failUpload) throw IllegalStateException("network down")
                uploads += grant
            },
        )
    }

    @Test
    fun `a changed grant is uploaded once and recorded`() = runBlocking {
        val r = Recorder(startReported = "while_in_use")

        assertTrue(r.reporter().reportIfChanged("background"))

        assertEquals(listOf("background"), r.uploads)
        assertEquals("background", r.reported)
    }

    @Test
    fun `the same grant costs no request`() = runBlocking {
        val r = Recorder(startReported = "background")

        assertFalse(r.reporter().reportIfChanged("background"))

        assertTrue(r.uploads.isEmpty())
        assertEquals("background", r.reported)
    }

    @Test
    fun `a first report after pairing is uploaded`() = runBlocking {
        val r = Recorder(startReported = null)

        assertTrue(r.reporter().reportIfChanged("none"))

        assertEquals(listOf("none"), r.uploads)
        assertEquals("none", r.reported)
    }

    @Test
    fun `a failed upload is not recorded, so the next resume retries`() = runBlocking {
        val r = Recorder(startReported = "while_in_use")

        val threw = runCatching { r.reporter(failUpload = true).reportIfChanged("background") }.isFailure

        assertTrue("the failure must surface to the caller's catch", threw)
        assertEquals("while_in_use", r.reported)
        // The retry with the same value uploads again, because nothing was recorded.
        assertTrue(r.reporter().reportIfChanged("background"))
        assertEquals(listOf("background"), r.uploads)
    }
}
