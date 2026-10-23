package com.familyshield.agent.push

import kotlinx.coroutines.CancellationException

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
     * Polls once, then falls back if it did not run; never inspects [data]. Cancellation is rethrown
     * (it is not a poll failure), and a failure to *enqueue* the fallback is swallowed because this is
     * the best-effort end of a push: it must not crash the messaging thread.
     */
    @Suppress("UNUSED_PARAMETER")
    suspend fun onPushReceived(
        data: Map<String, String>,
        poll: suspend () -> Unit,
        fallback: CommandFetchTrigger,
    ) {
        try {
            poll()
        } catch (cancelled: CancellationException) {
            throw cancelled
        } catch (failed: Exception) {
            runCatching { fallback.requestFetch() }
        }
    }
}
