package com.familyshield.agent.sos

/**
 * Pure countdown state machine for the Feature #14 SOS flow: idle -> counting -> fired/cancelled,
 * driven purely by caller-supplied millis so the pocket-dial-guard countdown is unit-testable
 * without Android.
 */
class SosStateMachine(private val countdownMs: Long = DEFAULT_COUNTDOWN_MS) {

    sealed class State {
        /** No countdown running (initial and after reset). */
        object Idle : State()

        /** Countdown running; [remainingMs] is recomputed on every tick. */
        data class Counting(val startedAtMs: Long, val remainingMs: Long) : State()

        /** Deadline reached; the SOS alert must be sent (exactly once). */
        object Fired : State()

        /** Cancelled by the child before the deadline; back to a re-armable state. */
        object Cancelled : State()
    }

    /** Current state; mutated only via [start]/[tick]/[cancel]/[reset]. */
    var state: State = State.Idle
        private set

    /** Starts the countdown from [nowMs]; no-op while already counting or after firing. */
    fun start(nowMs: Long): State {
        if (state == State.Idle || state == State.Cancelled) {
            state = State.Counting(nowMs, countdownMs)
        }
        return state
    }

    /** Advances the countdown to [nowMs]; transitions to Fired at (or past) the deadline. */
    fun tick(nowMs: Long): State {
        val s = state
        if (s is State.Counting) {
            val remaining = countdownMs - (nowMs - s.startedAtMs)
            state = if (remaining <= 0) State.Fired else State.Counting(s.startedAtMs, remaining)
        }
        return state
    }

    /** Cancels a running countdown (pocket-dial guard); no-op in any other state. */
    fun cancel(): State {
        if (state is State.Counting) state = State.Cancelled
        return state
    }

    /** Re-arms the machine to Idle (screen reset / after firing a new cycle). */
    fun reset(): State {
        state = State.Idle
        return state
    }

    companion object {
        /** SOS countdown length — long enough to abort an accidental press. */
        const val DEFAULT_COUNTDOWN_MS: Long = 5_000L
    }
}
