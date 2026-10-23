package com.familyshield.agent.push

import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.withTimeoutOrNull

/**
 * The fallback when the in-process poll cannot run: enqueue the one-shot poll worker. One method, so
 * a wake has no second channel through which a command could be dispatched.
 */
fun interface CommandFetchTrigger {
    /** Enqueues the same `GET /v1/devices/:id/commands` fetch the poller runs. */
    fun requestFetch()
}

/**
 * Claude's Decision 2 (#319, 2026-10-23), binding: **a push to a child device is a wake-up only** —
 * a high-priority FCM data message with no command type, payload or ids (for example `{ "w": "1" }`).
 * On it, the agent fetches `GET /v1/devices/:id/commands` over its own authenticated channel and acks
 * as it does today, so poll and push run through one code path with the same idempotent acks.
 *
 * The wake has exactly two steps, in this order:
 *  1. **Poll in-process, once** ([poll]). Lowest latency: the fetch starts on the FCM callback's own
 *     coroutine, which is what a `lock` needs.
 *  2. **Fall back to [fallback]** when that poll throws or cannot start. A `FirebaseMessagingService`
 *     has no `goAsync()`, so the process can be reclaimed as soon as the callback returns; work queued
 *     in WorkManager survives that, an in-process attempt does not.
 *
 * Why nothing in [data] is read: Google must never see command content. `show_reset_code` carries the
 * parent's reset code and a location request carries the timing of a family's day; a stale or
 * misdirected token must leak nothing, and it cannot if the message says nothing. The parameter is
 * accepted rather than dropped by the caller so the shape stays obvious and the tests can prove that
 * a `type=lock` message, `{"w":"1"}` and an empty map behave identically.
 *
 * There is deliberately no dispatch path here or in `FirebaseMessagingSvc`: no `CommandDispatcher` is
 * reachable from the service, and `CommandFetchTrigger` has one method.
 */
object PushWakeHandler {

    /**
     * How long a wake may spend polling before the work is handed to the one-shot worker.
     *
     * FCM gives `onMessageReceived` a short window (roughly 20 s) and then applies background limits
     * that can pause or terminate the process **without an exception** — so a poll cut short that way
     * would never reach the `catch`, the fallback would never be enqueued, and the command would wait
     * for the periodic poll, which is clamped to ~15 minutes. That is exactly the case 1.5's acceptance
     * is about (app backgrounded, phone dozing), so the budget has to be well inside the window.
     */
    const val WAKE_BUDGET_MS: Long = 8_000

    /**
     * Polls once inside [budgetMs], then falls back if the poll did not finish or threw. Never inspects
     * [data]. An **outer** cancellation is rethrown (it is not a poll failure), and a failure to
     * *enqueue* the fallback is swallowed because this is the best-effort end of a push: it must not
     * crash the messaging thread.
     */
    @Suppress("UNUSED_PARAMETER")
    suspend fun onPushReceived(
        data: Map<String, String>,
        poll: suspend () -> Unit,
        fallback: CommandFetchTrigger,
        budgetMs: Long = WAKE_BUDGET_MS,
    ) {
        // `withTimeoutOrNull` turns its *own* timeout into null, so a slow poll is indistinguishable
        // from a failed one here — both mean "enqueue the worker". A real outer cancellation still
        // surfaces as CancellationException from inside, so the rethrow below keeps its meaning.
        val finished = try {
            withTimeoutOrNull(budgetMs) {
                poll()
                true
            }
        } catch (cancelled: CancellationException) {
            throw cancelled
        } catch (failed: Exception) {
            null
        }
        if (finished == null) runCatching { fallback.requestFetch() }
    }
}
