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
 *    which is the old behaviour. While a lock or a pause is up it is [RESTRICTED_POLL_MS] instead
 *    (#673): those states are short, and a parent lifting one is waiting in front of the phone.
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

    /**
     * Issue #673: the interval while a lock or a pause is up, whatever the server says.
     *
     * The Flip4 run of 12 Nov timed `resume_internet` round 1 at 52.4 s: a paused phone shows the
     * overlay, so the screen is on, so the [INTERACTIVE_POLL_CAP_MS] rule gave a poll every 60 s and the
     * resume waited for it while the push that should have woken the phone was late. Both restricted
     * states are short and are exactly when a late push hurts, so they are polled ten times faster.
     * The idle budget (≤ 3 requests per 10 min, #353) is a statement about an *idle* phone: with no
     * restriction nothing here applies.
     *
     * The cost, stated rather than hidden: a phone left locked for an hour now sends up to 360 polls in
     * it, against the two an idle phone sends in ten minutes. That is the trade #673 asks for — a
     * restriction is a state a parent is watching, not an idle phone.
     *
     * Deliberately below [MIN_POLL_MS]: that floor exists so a bad `X-Poll-After` header cannot turn
     * the poll into a busy loop, and this value is ours, not the server's.
     */
    const val RESTRICTED_POLL_MS: Long = 10L * 1000L

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

    /**
     * The interval that applies right now: [RESTRICTED_POLL_MS] while a lock or a pause is up, else the
     * server's, capped while the screen is on.
     *
     * @param restricted a lock, a pause or a paused internet is active ([com.familyshield.agent.enforcement.LockState.isActive]).
     *   A restriction wins over both the server and the screen: a parent who just asked for the phone
     *   to stop is the parent most likely to ask again in seconds.
     */
    fun effectivePollMs(serverPollMs: Long, interactive: Boolean, restricted: Boolean = false): Long = when {
        restricted -> RESTRICTED_POLL_MS
        interactive -> minOf(serverPollMs, INTERACTIVE_POLL_CAP_MS)
        else -> serverPollMs
    }

    /**
     * True when a poll is due. [lastPollAtMs] and [nowMs] are on one monotonic clock
     * (`SystemClock.elapsedRealtime()`), so a wall-clock change can neither stall nor flood the poll.
     * [lastPollAtMs] null means this service has not polled yet: poll on the first tick.
     */
    fun pollDue(lastPollAtMs: Long?, nowMs: Long, serverPollMs: Long, interactive: Boolean, restricted: Boolean = false): Boolean {
        if (lastPollAtMs == null) return true
        return nowMs - lastPollAtMs >= effectivePollMs(serverPollMs, interactive, restricted)
    }

    /**
     * How long the loop waits before it next asks [pollDue] (#673). A 10 s rule read by a 15 s tick is a
     * 15 s poll, so the tick follows the state: while restricted the loop wakes at the interval it is
     * going to use. An unrestricted phone keeps the 15 s tick and its idle cost.
     */
    fun pollTickMs(restricted: Boolean): Long = POLL_TICK_MS

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
