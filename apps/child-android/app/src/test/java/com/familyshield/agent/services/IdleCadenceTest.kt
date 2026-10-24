package com.familyshield.agent.services

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Roadmap 5.8 (#353): the rules that took an idle phone from 22–24 requests per 10 minutes to about 2.
 * Pure JVM; [LocationServiceCadenceWiringTest] pins that the service's loops call these rules. The
 * phone-side number (≤ 3 per idle 10 minutes, screen off and dozing) is the hardware row in the PR.
 */
class IdleCadenceTest {

    private val minute = 60_000L

    // ---- X-Poll-After parsing -----------------------------------------------------------------

    @Test
    fun `the two values the server sends are honoured as they are`() {
        assertEquals(10 * minute, IdleCadence.pollAfterMs("600"))
        assertEquals(minute, IdleCadence.pollAfterMs("60"))
    }

    /** An older server sends no header: the agent keeps the 60 s it always had. */
    @Test
    fun `no header, an empty one, or garbage means the old 60 s poll`() {
        for (header in listOf(null, "", "  ", "soon", "60s", "1.5", "0", "-600")) {
            assertEquals("header <$header>", IdleCadence.DEFAULT_POLL_MS, IdleCadence.pollAfterMs(header))
        }
    }

    /**
     * Mutant: drop the clamp and a header of 1 polls on every 15 s tick, four times the old rate.
     * `Long.MAX_VALUE` is the overflow case: multiplied first, it wraps negative and would clamp to 30 s.
     */
    @Test
    fun `a value outside 30 s to 15 min is clamped, never trusted`() {
        assertEquals(30_000L, IdleCadence.pollAfterMs("1"))
        assertEquals(30_000L, IdleCadence.pollAfterMs("29"))
        assertEquals(15 * minute, IdleCadence.pollAfterMs("901"))
        assertEquals(15 * minute, IdleCadence.pollAfterMs("86400"))
        assertEquals(15 * minute, IdleCadence.pollAfterMs(Long.MAX_VALUE.toString()))
    }

    @Test
    fun `whitespace around the number is tolerated`() {
        assertEquals(10 * minute, IdleCadence.pollAfterMs(" 600 "))
    }

    // ---- When the poll is due ------------------------------------------------------------------

    @Test
    fun `the first tick after the service starts always polls`() {
        assertTrue(IdleCadence.pollDue(lastPollAtMs = null, nowMs = 0L, serverPollMs = 10 * minute, interactive = false))
    }

    /**
     * The lock guarantee without push: while the child is using the phone a lost push costs at most a
     * minute. Mutant: `effectivePollMs` ignores `interactive` and this fails at 61 s.
     */
    @Test
    fun `screen on caps the poll at 60 s even when the server says 600`() {
        val last = 1_000_000L
        assertFalse(IdleCadence.pollDue(last, last + 59_000L, 10 * minute, interactive = true))
        assertTrue(IdleCadence.pollDue(last, last + 61_000L, 10 * minute, interactive = true))
    }

    @Test
    fun `screen off follows the server's 600 s`() {
        val last = 1_000_000L
        assertFalse(IdleCadence.pollDue(last, last + 61_000L, 10 * minute, interactive = false))
        assertFalse(IdleCadence.pollDue(last, last + 9 * minute, 10 * minute, interactive = false))
        assertTrue(IdleCadence.pollDue(last, last + 10 * minute, 10 * minute, interactive = false))
    }

    /** The cap only ever shortens: a server that says 30 s while the screen is on gets 30 s. */
    @Test
    fun `a server value under the cap is kept with the screen on`() {
        assertEquals(30_000L, IdleCadence.effectivePollMs(30_000L, interactive = true))
        assertEquals(minute, IdleCadence.effectivePollMs(10 * minute, interactive = true))
        assertEquals(10 * minute, IdleCadence.effectivePollMs(10 * minute, interactive = false))
    }

    /** With no push the server says 60 and the phone polls exactly as before, screen on or off. */
    @Test
    fun `without push nothing changes`() {
        val last = 5_000L
        for (interactive in listOf(true, false)) {
            assertFalse(IdleCadence.pollDue(last, last + 59_000L, minute, interactive))
            assertTrue(IdleCadence.pollDue(last, last + minute, minute, interactive))
        }
    }

    /** The loop ticks every 15 s, so turning the screen on brings an overdue poll within one tick. */
    @Test
    fun `the tick is short enough that a screen-on poll is never more than 15 s late`() {
        assertEquals(15_000L, IdleCadence.POLL_TICK_MS)
        assertTrue(IdleCadence.POLL_TICK_MS < IdleCadence.INTERACTIVE_POLL_CAP_MS)
        assertTrue(IdleCadence.POLL_TICK_MS <= IdleCadence.MIN_POLL_MS)
    }

    // ---- Live activity ----------------------------------------------------------------------------

    /** Mutant: return `interactive` alone and the screen-off "idle" snapshot is never sent. */
    @Test
    fun `live activity runs while the screen is on and once after it turns off`() {
        assertTrue("screen on", IdleCadence.shouldPostLiveActivity(interactive = true, wasInteractive = true))
        assertTrue("screen just turned on", IdleCadence.shouldPostLiveActivity(interactive = true, wasInteractive = false))
        assertTrue("screen just turned off: the last, idle snapshot", IdleCadence.shouldPostLiveActivity(interactive = false, wasInteractive = true))
        assertFalse("screen stayed off", IdleCadence.shouldPostLiveActivity(interactive = false, wasInteractive = false))
    }

    // ---- Location flush -------------------------------------------------------------------------

    private fun flush(
        moving: Boolean = false,
        paused: Boolean = false,
        since: Long? = 0L,
        stored: Boolean = false,
        now: Long,
    ) = IdleCadence.shouldFlushPings(moving, paused, since, stored, now)

    /** Mutant: flush whenever anything is buffered (the old rule) and the 5-minute case flushes. */
    @Test
    fun `a stationary batch waits until its oldest ping is 10 minutes old`() {
        assertFalse(flush(now = 5 * minute))
        assertFalse(flush(now = 10 * minute - 1))
        assertTrue(flush(now = 10 * minute))
    }

    @Test
    fun `moving flushes on the next tick, as before`() {
        assertTrue(flush(moving = true, now = 1_000L))
    }

    @Test
    fun `nothing buffered and nothing stored sends nothing`() {
        assertFalse(flush(since = null, now = 60 * minute))
        assertFalse(flush(moving = true, since = null, now = 60 * minute))
    }

    /** A batch that failed to upload is retried on the next tick, not held for 10 minutes. */
    @Test
    fun `a batch waiting in Room after a failure is retried at once`() {
        assertTrue(flush(since = null, stored = true, now = 1_000L))
        assertTrue(flush(since = 0L, stored = true, now = 1_000L))
    }

    /**
     * ADR-0008 §3: withdrawal stops collection, and `flushPings` is where buffered pings are discarded.
     * Mutant: drop the `paused` branch and a paused phone holds up to 10 minutes of pings.
     */
    @Test
    fun `a consent pause always reaches flushPings, which discards`() {
        assertTrue(flush(paused = true, since = 0L, now = 1_000L))
        assertTrue(flush(paused = true, since = null, now = 1_000L))
    }

    /** Two 5-minute fixes per request: the flush age must be at least two stationary intervals. */
    @Test
    fun `the flush age holds two stationary fixes and stays well inside the silence window`() {
        assertEquals(10 * minute, IdleCadence.STATIONARY_FLUSH_AGE_MS)
        assertTrue(IdleCadence.STATIONARY_FLUSH_AGE_MS < 30 * minute) // DEVICE_SILENT_MINUTES default
    }
    // ---- CommandPollWorker ----------------------------------------------------------------------

    /**
     * Mutant: make [IdleCadence.workerShouldPoll] return true and the 60 s WorkManager job fetches
     * beside the service's own poll, so an idle phone is back over budget. This test fails then.
     */
    @Test
    fun `the periodic worker skips while LocationService runs and nothing woke it`() {
        assertFalse(IdleCadence.workerShouldPoll(locationServiceRunning = true, wake = false))
    }

    /** Mutant: drop `wake ||` and a push-woken run is skipped, so a lock waits up to 10 min in Doze. */
    @Test
    fun `a push-woken run always polls, even while LocationService runs`() {
        assertTrue(IdleCadence.workerShouldPoll(locationServiceRunning = true, wake = true))
        assertTrue(IdleCadence.workerShouldPoll(locationServiceRunning = false, wake = true))
    }

    /** Mutant: return `wake` alone and a phone without the service never polls on its own. */
    @Test
    fun `with LocationService off the periodic worker is the poll and runs`() {
        assertTrue(IdleCadence.workerShouldPoll(locationServiceRunning = false, wake = false))
    }
}
