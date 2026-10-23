package com.familyshield.agent.push

import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.delay
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertThrows
import org.junit.Test

/**
 * Claude's Decision 2 (#319, 2026-10-23), the shape he specified for the wake: the push handler polls
 * **in-process once** and falls back to the one-shot worker only when that poll throws or cannot run.
 *
 * Pure JVM: the poll is a `suspend () -> Unit` and the fallback is a [CommandFetchTrigger], so there is
 * no Firebase, no `google-services.json` and no Robolectric. What is out of reach here: that the
 * in-process HTTP call reaches the server and that the worker runs — that is the phone row.
 */
class PushWakeHandlerTest {

    /** Counts the two things a wake may do; anything else has no channel by construction. */
    private class Recorder {
        var polls = 0
            private set
        var fallbacks = 0
            private set

        val trigger = CommandFetchTrigger { fallbacks++ }

        suspend fun poll() {
            polls++
        }
    }

    /**
     * The primary path: one in-process poll, and the worker is **not** enqueued as well — a second
     * fetch per push would be a duplicate request and a duplicate dispatch/ack.
     *
     * Mutant: call `poll()` twice in [PushWakeHandler.onPushReceived] (or always call the fallback)
     * and this fails with `expected:<1> but was:<2>` (or a non-zero fallback count).
     */
    @Test
    fun `a message triggers exactly one in-process poll`() = runBlocking {
        val recorder = Recorder()

        PushWakeHandler.onPushReceived(
            data = mapOf("type" to "lock"),
            poll = { recorder.poll() },
            fallback = recorder.trigger,
        )

        assertEquals("a push must poll exactly once in-process", 1, recorder.polls)
        assertEquals("a successful poll must not also enqueue the worker", 0, recorder.fallbacks)
    }

    /**
     * The fallback: when the in-process poll throws (offline, no device id, WorkManager-less process
     * teardown — the handler only knows "it threw"), exactly one one-shot worker is requested and the
     * poll is not retried here. Retrying in-process is the worker's job, with its own backoff.
     *
     * Mutant: delete the `catch (failed: Exception)` branch (fallback stays 0) or call `poll()` again
     * inside the catch (polls becomes 2); either one fails below.
     */
    @Test
    fun `a throwing poll triggers exactly one fallback and no second poll`() = runBlocking {
        val recorder = Recorder()

        PushWakeHandler.onPushReceived(
            data = mapOf("type" to "lock"),
            poll = {
                recorder.poll()
                throw IllegalStateException("offline")
            },
            fallback = recorder.trigger,
        )

        assertEquals("a failed in-process poll must not be retried in-process", 1, recorder.polls)
        assertEquals("a failed in-process poll must enqueue the worker once", 1, recorder.fallbacks)
    }

    /**
     * Content is never read: a message that looks like the old dispatch shape, the production wake-up
     * `{"w":"1"}`, and an empty map must all behave identically. If the handler ever regains the old
     * `val type = data["type"] ?: return` gate, real wake-ups silently stop polling.
     *
     * Mutant: add `if (data["type"] == null) return` at the top of
     * [PushWakeHandler.onPushReceived] → the `{"w":"1"}` and empty-map iterations fail with
     * `expected:<1> but was:<0>` while the `type=lock` iteration stays green.
     */
    @Test
    fun `the message content is never read`() = runBlocking {
        val messages = listOf(
            mapOf("type" to "lock", "commandId" to "cmd-319", "payload" to """{"minutes":10}"""),
            mapOf("w" to "1"),
            emptyMap(),
        )

        for (message in messages) {
            val recorder = Recorder()
            PushWakeHandler.onPushReceived(
                data = message,
                poll = { recorder.poll() },
                fallback = recorder.trigger,
            )
            assertEquals("message $message must poll exactly once", 1, recorder.polls)
            assertEquals("message $message must not enqueue the worker", 0, recorder.fallbacks)
        }
    }

    /**
     * Cancellation is not a poll failure: a cancelled scope must not queue a worker. The handler
     * rethrows it so structured concurrency keeps working.
     *
     * Mutant: drop the `catch (cancelled: CancellationException) { throw cancelled }` branch (plain
     * `catch (e: Exception)` instead) and this fails — nothing is thrown, so `assertThrows` reports
     * `Expected exception: java.util.concurrent.CancellationException`.
     */
    @Test
    fun `cancellation is rethrown and does not enqueue the fallback`() {
        val recorder = Recorder()

        assertThrows(CancellationException::class.java) {
            runBlocking {
                PushWakeHandler.onPushReceived(
                    data = mapOf("w" to "1"),
                    poll = { throw CancellationException("scope gone") },
                    fallback = recorder.trigger,
                )
            }
        }

        assertEquals("a cancelled poll is not a failure to recover from", 0, recorder.fallbacks)
    }

    /**
     * A poll that has not finished inside the wake budget is handed to the worker as well.
     *
     * This is the case the acceptance row is actually about: FCM's callback window closes and the
     * process is paused or reclaimed **without an exception**, so a slow in-process poll cannot be
     * allowed to be the only attempt. A short real budget (50 ms against a 400 ms poll) keeps the test
     * fast without adding `kotlinx-coroutines-test` for virtual time.
     *
     * Mutant: drop `withTimeoutOrNull(...)` from `PushWakeHandler.onPushReceived` and this fails with
     * `fallbacks expected:<1> but was:<0>` after the poll runs to completion.
     */
    @Test
    fun `a poll that overruns the wake budget also enqueues the worker`() = runBlocking {
        val recorder = Recorder()

        PushWakeHandler.onPushReceived(
            data = mapOf("w" to "1"),
            poll = {
                recorder.poll()
                delay(400)
            },
            fallback = recorder.trigger,
            budgetMs = 50,
        )

        assertEquals("the overrunning poll still ran exactly once", 1, recorder.polls)
        assertEquals("an unfinished poll must be handed to the worker", 1, recorder.fallbacks)
    }
}
