package com.familyshield.agent.commands

import java.io.File
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Roadmap 5.8 (#353): [com.familyshield.agent.services.IdleCadenceTest] proves the worker rule; this
 * pins that [CommandPollWorker] goes through it and that a push-woken run is marked as one. The worker
 * needs WorkManager and a Hilt entry point, so its source is read instead, as
 * [com.familyshield.agent.services.LocationServiceCadenceWiringTest] does for the service.
 */
class CommandPollWorkerCadenceWiringTest {

    private val source = sourceFile("app/src/main/java/com/familyshield/agent/commands/CommandPollWorker.kt").readText()

    /**
     * Mutant: delete the `workerShouldPoll` guard and the 60 s periodic job fetches beside
     * LocationService's own poll, so an idle phone is back to 10 extra requests per 10 minutes.
     */
    @Test
    fun `doWork asks IdleCadence before polling, with the service state and the wake flag`() {
        val start = source.indexOf("override suspend fun doWork()")
        assertTrue("CommandPollWorker no longer declares doWork()", start >= 0)
        val body = source.substring(start, source.indexOf("override suspend fun getForegroundInfo()"))
        assertTrue(body.contains("inputData.getBoolean(KEY_WAKE, false)"))
        assertTrue(
            "the skip must come before the fetch",
            body.indexOf("IdleCadence.workerShouldPoll(LocationService.isServiceRunning, wake)") in 0 until body.indexOf("pollOnce()"),
        )
    }

    /**
     * Mutant: drop `.setInputData(workDataOf(KEY_WAKE to true))` and a push-woken run looks periodic,
     * so while LocationService runs it is skipped and a lock on a dozing phone waits for the next poll.
     */
    @Test
    fun `requestFetchNow marks its run as a wake`() {
        val start = source.indexOf("fun requestFetchNow(")
        assertTrue("CommandPollWorker no longer declares requestFetchNow", start >= 0)
        assertTrue(source.substring(start).contains(".setInputData(workDataOf(KEY_WAKE to true))"))
    }

    /** Walks up from the Gradle working directory (the `app` module) to the repository root. */
    private fun sourceFile(relative: String): File {
        var dir: File? = File(System.getProperty("user.dir") ?: ".").absoluteFile
        while (dir != null) {
            val candidate = File(dir, relative)
            if (candidate.isFile) return candidate
            dir = dir.parentFile
        }
        throw AssertionError("could not find $relative from ${System.getProperty("user.dir")}")
    }
}
