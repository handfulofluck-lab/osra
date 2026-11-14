package com.familyshield.agent.security

/**
 * osra-security#24: the wrong-PIN count must survive the screen, and a lockout must grow.
 *
 * The count used to live in a field on [TamperGuardActivity], so reopening the guarded screen — settings,
 * uninstall, re-pair, the ring's stop — started again at zero. A 4-digit PIN is 10,000 values; five tries
 * per reopen, no delay between rounds, and a patient child gets through in hours. The PIN unlocks every
 * protection-removal path and stops a ring, and the child-escape catalogue already required this: AG02
 * ("the attempt counter survives restarts; back-off grows") and E12 ("five wrong tries lock the gate for a
 * while and alert the parent").
 *
 * The rule lives here, free of Android types, for the same reason [GuardAttemptWindow] does: the activity
 * cannot run in a JVM test, so every decision it makes is a function the tests can drive.
 *
 * **Two directions that are wrong, and the choices that avoid them:**
 * - A lockout that a clock change clears is not a lockout. A time moved backwards from the last failure
 *   reads as **inside** the window, not outside it.
 * - A lockout that refuses nothing is a message. [isLocked] is checked before the PIN is verified, so the
 *   right PIN is refused too — that is the point of a back-off.
 */
object PinLockout {

    /** The attempt that triggers the first lockout. Matches the gate's existing five-try rule. */
    const val MAX_ATTEMPTS: Int = 5

    /**
     * How long the gate stays closed after the fifth failure, the sixth, the seventh, and then flat:
     * 1 min, 5 min, 15 min, 1 h. Growing, because a child who keeps trying is telling us something a fixed
     * window does not answer.
     */
    val WINDOWS_MS: LongArray = longArrayOf(
        60_000L,
        5 * 60_000L,
        15 * 60_000L,
        60 * 60_000L,
    )

    /**
     * [failures] and [lastFailureMs] are persisted; [alertedAt] is the failure count the parent was last
     * alerted for, which is what makes one alert per lockout rather than one per attempt.
     */
    data class State(
        val failures: Int = 0,
        val lastFailureMs: Long = 0L,
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
     * True while the gate must refuse **every** PIN, the right one included.
     *
     * A clock that reads earlier than the last failure is inside the window, not outside it: moving the
     * phone's clock back must not hand the gate open.
     */
    fun isLocked(state: State, nowMs: Long): Boolean {
        if (state.failures < MAX_ATTEMPTS || state.lastFailureMs == 0L) return false
        val window = lockWindowMs(state.failures)
        if (nowMs < state.lastFailureMs) return true
        return nowMs - state.lastFailureMs < window
    }

    /** Milliseconds left in the lockout; zero when the gate is open. Never negative. */
    fun remainingMs(state: State, nowMs: Long): Long {
        if (!isLocked(state, nowMs)) return 0L
        val window = lockWindowMs(state.failures)
        if (nowMs < state.lastFailureMs) return window
        return (window - (nowMs - state.lastFailureMs)).coerceAtLeast(0L)
    }

    /**
     * Folds one wrong PIN in at [nowMs].
     *
     * The count is deliberately **not** reset when a window expires: the next failure must escalate, or a
     * child gets 1 min, 1 min, 1 min forever by waiting. Only [CLEARED], after a correct PIN, goes back to
     * zero.
     */
    fun recordFailure(state: State, nowMs: Long): State =
        state.copy(failures = state.failures + 1, lastFailureMs = nowMs)

    /**
     * True when this lockout has not been reported yet. One alert per lockout: the parent is told the gate
     * is closed, not told again for every further attempt inside the same closed gate.
     */
    fun shouldAlert(state: State): Boolean =
        state.failures >= MAX_ATTEMPTS && state.alertedAt < state.failures

    /** Records that the parent was alerted for the failures counted so far. */
    fun markedAlerted(state: State): State = state.copy(alertedAt = state.failures)

    /** What the child reads while the gate is closed. One line, no number for them to work with. */
    fun lockoutNotice(remainingMs: Long): String {
        val minutes = ((remainingMs + 59_999L) / 60_000L).coerceAtLeast(1L)
        val forHowLong = if (minutes == 1L) "1 minute" else "$minutes minutes"
        return "Too many tries. Try again in $forHowLong, or ask your parent."
    }
}
