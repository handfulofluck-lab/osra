package com.familyshield.agent.security

/**
 * osra-security#24: the wrong-PIN count must survive the screen, and repeated failures must have to wait,
 * growing each time. The count used to live in a field on [TamperGuardActivity], so every reopen began again
 * at zero. The catalogue rows that require this are AG02 ("the attempt counter survives restarts; back-off
 * grows") and E12 ("five wrong tries lock the gate for a while and alert the parent"); the scenario itself
 * stays in osra-security#24.
 *
 * The rule lives here, free of Android types, so the activity's decisions are functions the tests can drive.
 *
 * **Time.** Only the monotonic clock decides a window: [State.lastFailureElapsedMs] against the caller's
 * `SystemClock.elapsedRealtime()`. The wall clock is stored ([State.lastFailureMs]) for the alert and for a
 * human reading the state, and is never compared — so moving the phone's clock, forward or back, neither
 * opens nor extends a lockout. A reboot invalidates the monotonic clock, so [anchored] re-anchors the window
 * to "one full window from the first read after boot"; a reboot therefore costs the child a fresh window and
 * can never cost the parent more than one. A state read without anchoring is open, never stuck.
 */
object PinLockout {

    /** The attempt that triggers the first lockout. Matches the gate's five-try rule. */
    const val MAX_ATTEMPTS: Int = 5

    /** No boot has been recorded yet; a state carrying it is never "from another boot". */
    const val NO_BOOT: Int = -1

    /** How long the gate stays closed after the fifth failure, the sixth, the seventh, and then flat. */
    val WINDOWS_MS: LongArray = longArrayOf(
        60_000L,
        5 * 60_000L,
        15 * 60_000L,
        60 * 60_000L,
    )

    /**
     * [failures], [lastFailureMs] (wall), [lastFailureElapsedMs] (monotonic) and [lastFailureBootCount] are
     * persisted; [alertedAt] is the failure count the parent was last alerted for, which is what makes one
     * alert per lockout rather than one per attempt.
     */
    data class State(
        val failures: Int = 0,
        val lastFailureMs: Long = 0L,
        val lastFailureElapsedMs: Long = 0L,
        val lastFailureBootCount: Int = NO_BOOT,
        val alertedAt: Int = 0,
    )

    /** The empty state: no failures, nothing to lock, nothing to alert. */
    val CLEARED: State = State()

    /** The lockout length after [failures] wrong tries; zero below [MAX_ATTEMPTS], flat after the last window. */
    fun lockWindowMs(failures: Int): Long {
        if (failures < MAX_ATTEMPTS) return 0L
        val step = (failures - MAX_ATTEMPTS).coerceIn(0, WINDOWS_MS.size - 1)
        return WINDOWS_MS[step]
    }

    /**
     * The state to judge, with a window carried across a reboot re-anchored to now.
     *
     * Called on every open and on every attempt, before [isLocked]: after a reboot the monotonic clock has
     * restarted, so the stored reading means nothing and the window starts again from here. A state whose
     * boot matches **and** whose monotonic reading has not gone backwards, or that is not locked, comes back
     * unchanged so the caller can skip the write.
     *
     * The elapsed comparison matters on its own: when `Settings.Global.BOOT_COUNT` cannot be read, both
     * sides carry [NO_BOOT] and the boot count proves nothing. A monotonic clock that reads lower than the
     * stored one is proof of a reboot by itself — and without this condition the gate would stay shut until
     * the new uptime caught up with the old, which on a phone that had been up for days is days.
     */
    fun anchored(state: State, nowWallMs: Long, nowElapsedMs: Long, nowBootCount: Int): State {
        if (state.failures < MAX_ATTEMPTS || state.lastFailureMs == 0L) return state
        if (nowBootCount == state.lastFailureBootCount && nowElapsedMs >= state.lastFailureElapsedMs) return state
        return state.copy(
            lastFailureMs = nowWallMs,
            lastFailureElapsedMs = nowElapsedMs,
            lastFailureBootCount = nowBootCount,
        )
    }

    /**
     * True while the gate must refuse **every** PIN, the right one included.
     *
     * [nowElapsedMs] is `SystemClock.elapsedRealtime()`. The wall clock is deliberately not a parameter:
     * a comparison against it is what lets a changed clock open the gate early or hold it shut forever.
     */
    fun isLocked(state: State, nowElapsedMs: Long): Boolean {
        if (state.failures < MAX_ATTEMPTS || state.lastFailureMs == 0L) return false
        return nowElapsedMs - state.lastFailureElapsedMs < lockWindowMs(state.failures)
    }

    /** Milliseconds left in the lockout; zero when the gate is open. Never negative. */
    fun remainingMs(state: State, nowElapsedMs: Long): Long {
        if (!isLocked(state, nowElapsedMs)) return 0L
        return (lockWindowMs(state.failures) - (nowElapsedMs - state.lastFailureElapsedMs)).coerceAtLeast(0L)
    }

    /** The minutes to show in the notice, rounded up so "1 minute" is never "0 minutes". */
    fun remainingMinutes(state: State, nowElapsedMs: Long): Int =
        (((remainingMs(state, nowElapsedMs) + 59_999L) / 60_000L).coerceAtLeast(1L)).toInt()

    /**
     * Folds one wrong PIN in.
     *
     * The count is deliberately **not** reset when a window expires: the next failure must escalate, or a
     * child gets 1 min, 1 min, 1 min forever by waiting. Only [CLEARED], after a correct PIN, goes back to
     * zero.
     */
    fun recordFailure(state: State, nowWallMs: Long, nowElapsedMs: Long, nowBootCount: Int): State =
        state.copy(
            failures = state.failures + 1,
            lastFailureMs = nowWallMs,
            lastFailureElapsedMs = nowElapsedMs,
            lastFailureBootCount = nowBootCount,
        )

    /**
     * True when this lockout has not been reported yet. One alert per lockout: the parent is told the gate
     * is closed, not told again for every further attempt inside the same closed gate.
     */
    fun shouldAlert(state: State): Boolean =
        state.failures >= MAX_ATTEMPTS && state.alertedAt < state.failures

    /** Records that the parent was alerted for the failures counted so far. */
    fun markedAlerted(state: State): State = state.copy(alertedAt = state.failures)
}
