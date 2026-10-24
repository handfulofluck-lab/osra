package com.familyshield.agent.services

import java.io.File
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Roadmap 5.8 (#353): [IdleCadenceTest] proves the rules; this pins that [LocationService]'s loops
 * actually go through them. The service is an Android `Service` with Hilt fields and a coroutine
 * loop, so it does not run on the JVM; its source is read instead, the same way
 * [FirebaseMessagingSvcWiringTest] pins the push path. Out of reach here: the request count on a
 * real idle phone, which is the hardware row in the PR (≤ 3 per 10 minutes, screen off and dozing).
 */
class LocationServiceCadenceWiringTest {

    private val source = sourceFile("app/src/main/java/com/familyshield/agent/services/LocationService.kt").readText()

    /** The text of one member, from its declaration to the next member at the same indent. */
    private fun body(declaration: String): String {
        val start = source.indexOf(declaration)
        assertTrue("LocationService no longer declares `$declaration`", start >= 0)
        val next = Regex("\n    (?:/\\*\\*|private |internal |override |suspend |fun |companion )").find(source, start + declaration.length)
        return source.substring(start, next?.range?.first ?: source.length)
    }

    private val onStart get() = body("override fun onStartCommand(")

    /**
     * Mutant: put back `delay(COMMAND_POLL_INTERVAL_MS); pollCommandsOnce()` and this fails — the
     * phone polls every 60 s whatever the server says, which is 10 of the 22 idle requests.
     */
    @Test
    fun `the command loop ticks and asks IdleCadence whether a poll is due`() {
        val loop = onStart
        assertTrue("the loop waits one IdleCadence.POLL_TICK_MS per turn", loop.contains("delay(IdleCadence.POLL_TICK_MS)"))
        assertTrue(
            "the loop polls only when IdleCadence.pollDue says so, with the server's interval and the screen state",
            loop.contains("IdleCadence.pollDue(lastPollAtMs, now, serverPollMs, isInteractive())"),
        )
        assertTrue("the clock is monotonic, so a clock change cannot stall the poll", loop.contains("SystemClock.elapsedRealtime()"))
        assertFalse("the fixed 60 s poll constant is gone", source.contains("COMMAND_POLL_INTERVAL_MS"))
    }

    /**
     * Mutant: call `api.getCommands(deviceId)` again and the header is never read, so the phone stays
     * at 60 s. Second mutant: drop the `HttpException` and a 428 reads as an empty, successful poll,
     * so a phone whose consent was withdrawn would never pause (ADR-0008 §3).
     */
    @Test
    fun `the poll reads X-Poll-After and keeps the 428 consent path`() {
        val poll = body("private suspend fun pollCommandsOnce()")
        assertTrue(poll.contains("api.getCommandsWithCadence(deviceId)"))
        assertFalse("the header-less call must not come back here", poll.contains("api.getCommands("))
        assertTrue("a non-2xx answer must still throw", poll.contains("if (!response.isSuccessful) throw HttpException(response)"))
        assertTrue(poll.contains("serverPollMs = IdleCadence.pollAfterMs(response.headers()[IdleCadence.POLL_AFTER_HEADER])"))
        assertTrue("a failed poll falls back to 60 s", poll.contains("serverPollMs = IdleCadence.DEFAULT_POLL_MS"))
        assertTrue("the 428 still reaches ConsentState", poll.contains("consentState.onPollFailure(it)"))
    }

    /** Mutant: post live activity on every tick again and a screen-off phone sends one a minute (12 of 23 in phase A). */
    @Test
    fun `live activity is posted only when IdleCadence says so, and idle once the screen is off`() {
        val loop = onStart
        assertTrue(loop.contains("if (IdleCadence.shouldPostLiveActivity(interactive, wasInteractive))"))
        assertTrue("the screen-off snapshot must report idle", loop.contains("usage.postLiveActivity(screenOn = interactive)"))
        assertFalse("no unconditional post in the loop", loop.contains("runCatching { usage.postLiveActivity() }"))
        assertTrue("the edge needs the previous state carried between ticks", loop.contains("wasInteractive = interactive"))
    }

    /** Mutant: `runCatching { flushPings() }` unguarded in the loop and a stationary phone sends every 5 minutes. */
    @Test
    fun `the periodic flush goes through the IdleCadence flush rule`() {
        val loop = onStart
        assertTrue(loop.contains("if (shouldFlushNow()) flushPings()"))
        assertFalse("no unconditional periodic flush", loop.contains("runCatching { flushPings() }"))

        val rule = body("private suspend fun shouldFlushNow()")
        assertTrue(rule.contains("IdleCadence.shouldFlushPings("))
        assertTrue("a pause must still reach flushPings, which discards", rule.contains("paused = consentState.isPaused()"))
        assertTrue("moving is the 30 s interval", rule.contains("moving = intervalMs == MOVING_INTERVAL_MS"))
        assertTrue("a failed batch in Room is retried", rule.contains("hasStoredBatch = stored"))
    }

    /** Mutant: stamp `bufferedSinceMs` on every ping and a stationary batch never ages to 10 minutes. */
    @Test
    fun `the batch age starts with the first ping into an empty buffer`() {
        val onLocation = body("private fun onLocation(")
        assertTrue(onLocation.contains("if (memoryPings.isEmpty()) bufferedSinceMs = SystemClock.elapsedRealtime()"))
    }

    /** locate_now is a parent waiting on a map: it must not wait for the 10-minute batch. */
    @Test
    fun `locate_now still flushes at once`() {
        val locate = body("private suspend fun locateNowOnce(")
        assertTrue(locate.contains("runCatching { flushPings() }"))
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
