package com.familyshield.agent.services

/**
 * Roadmap 5.8 (#353): how often [LocationService] talks to the server while the phone sits idle.
 *
 * Measured on the Flip4 with #346's counter, an idle phone sent 22 to 24 requests per 10 minutes,
 * awake or dozing, against a budget of 3. All three calls came from this service's loops, and a
 * foreground service keeps its network in Doze, so Doze changed nothing. The rules here bring the
 * idle cost to about 2 per 10 minutes:
 *
 *  - **Commands poll.** The server answers `GET /v1/devices/:id/commands` with `X-Poll-After`:
 *    600 s when it can wake this phone by push, 60 s otherwise (`services/api/src/lib/pollCadence.ts`).
 *    The agent honours it, clamped to [MIN_POLL_MS]..[MAX_POLL_MS], and polls at least every
 *    [INTERACTIVE_POLL_CAP_MS] while the screen is on, so a lost push still costs a child using the
 *    phone at most a minute. A missing or unreadable header (an older server) means [DEFAULT_POLL_MS],
 *    which is the old behaviour.
 *  - **Live activity** (Feature #29) is posted only while the screen is on, plus once on the first
 *    tick after it turns off, so the parent's "now using" line ends on "idle" instead of the last app.
 *  - **Stationary location** is flushed when the oldest buffered ping is [STATIONARY_FLUSH_AGE_MS]
 *    old: two 5-minute fixes per request. Moving, `locate_now`, a consent pause (which discards) and
 *    a batch waiting in Room after a failed upload flush on the next tick, as before.
 *  - **The WorkManager poll** ([workerShouldPoll]) skips its periodic run while this service is
 *    running; a push-woken run still fetches.
 *
 * Pure so the rules are JVM-tested ([IdleCadenceTest]); [LocationServiceCadenceWiringTest] pins that
 * the service's loops go through them.
 */
object IdleCadence {

    /** Response header the server sets on the commands poll. Must match `POLL_AFTER_HEADER` in the API. */
    const val POLL_AFTER_HEADER: String = "X-Poll-After"

    /** The cadence when the server says nothing: the 60 s poll this service always had. */
    const val DEFAULT_POLL_MS: Long = 60L * 1000L

    /** Floor for a server-sent value, so a bad header cannot turn the poll into a busy loop. */
    const val MIN_POLL_MS: Long = 30L * 1000L

    /** Ceiling for a server-sent value: a lost push is never more than 15 minutes from a poll. */
    const val MAX_POLL_MS: Long = 15L * 60L * 1000L

    /** While the screen is on the poll runs at least this often, whatever the server says. */
    const val INTERACTIVE_POLL_CAP_MS: Long = 60L * 1000L

    /** How often the poll loop wakes to check [pollDue]; a tick with nothing due sends nothing. */
    const val POLL_TICK_MS: Long = 15L * 1000L

    /** A stationary batch goes up when its oldest ping has waited this long. */
    const val STATIONARY_FLUSH_AGE_MS: Long = 10L * 60L * 1000L

    /**
     * Parses `X-Poll-After` (whole seconds) into milliseconds, clamped to [MIN_POLL_MS]..[MAX_POLL_MS].
     * Anything else (absent, empty, not a number, zero or negative) is [DEFAULT_POLL_MS].
     */
    fun pollAfterMs(header: String?): Long {
        val seconds = header?.trim()?.toLongOrNull() ?: return DEFAULT_POLL_MS
        if (seconds <= 0L) return DEFAULT_POLL_MS
        // Clamp the seconds before multiplying: a huge header must not overflow into a short poll.
        val ms = if (seconds >= MAX_POLL_MS / 1000L) MAX_POLL_MS else seconds * 1000L
        return ms.coerceIn(MIN_POLL_MS, MAX_POLL_MS)
    }

    /** The interval that applies right now: the server's, capped while the screen is on. */
    fun effectivePollMs(serverPollMs: Long, interactive: Boolean): Long =
        if (interactive) minOf(serverPollMs, INTERACTIVE_POLL_CAP_MS) else serverPollMs

    /**
     * True when a poll is due. [lastPollAtMs] and [nowMs] are on one monotonic clock
     * (`SystemClock.elapsedRealtime()`), so a wall-clock change can neither stall nor flood the poll.
     * [lastPollAtMs] null means this service has not polled yet: poll on the first tick.
     */
    fun pollDue(lastPollAtMs: Long?, nowMs: Long, serverPollMs: Long, interactive: Boolean): Boolean {
        if (lastPollAtMs == null) return true
        return nowMs - lastPollAtMs >= effectivePollMs(serverPollMs, interactive)
    }

    /**
     * True when a `CommandPollWorker` run should fetch. The periodic 60-second job is a backstop for
     * when [LocationService] is not running; while it runs, the service's own poll (paced by
     * [pollDue]) covers commands, and a second 60-second fetch would undo the idle budget. A run a
     * push woke (`requestFetchNow`) always fetches, because that is how a lock reaches a dozing phone.
     */
    fun workerShouldPoll(locationServiceRunning: Boolean, wake: Boolean): Boolean =
        wake || !locationServiceRunning

    /** Live activity goes up while the screen is on, and once more on the tick after it turns off. */
    fun shouldPostLiveActivity(interactive: Boolean, wasInteractive: Boolean): Boolean =
        interactive || wasInteractive

    /**
     * True when the periodic tick should call `flushPings`.
     *
     * @param bufferedSinceMs when the oldest ping still in memory was buffered, on the same monotonic
     *   clock as [nowMs] (`SystemClock.elapsedRealtime()`), or null when the memory buffer is empty.
     * @param hasStoredBatch a batch is waiting in Room after a failed upload.
     */
    fun shouldFlushPings(
        moving: Boolean,
        paused: Boolean,
        bufferedSinceMs: Long?,
        hasStoredBatch: Boolean,
        nowMs: Long,
    ): Boolean {
        if (paused) return true // flushPings discards while paused (ADR-0008 §3); never hold pings
        if (hasStoredBatch) return true
        if (bufferedSinceMs == null) return false
        if (moving) return true
        return nowMs - bufferedSinceMs >= STATIONARY_FLUSH_AGE_MS
    }
}
