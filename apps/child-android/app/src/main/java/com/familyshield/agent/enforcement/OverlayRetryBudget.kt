package com.familyshield.agent.enforcement

/** Outcome of asking [OverlayRetryBudget] for another overlay raise. */
enum class RetryDecision {
    /** The caller may raise the overlay now. */
    ATTEMPT,

    /** The budget for this screen state is exhausted; log once, then do nothing. */
    EXHAUSTED_ONCE,

    /** Already logged for this screen state; stay quiet. */
    EXHAUSTED,
}

/**
 * Issue #175: a bounded retry for a re-raise the platform may refuse.
 *
 * There is no public API to close **another app's** PiP window (`setPictureInPictureParams` is the
 * target's method), and a split screen can survive a launch on Android 12+ large screens even for a
 * `resizeableActivity="false"` activity. The service therefore re-raises the overlay when it sees a
 * multi-window state — but a fixed state must not produce an activity start on every accessibility
 * event forever. This budget allows [maxAttempts] raises per screen [signature]; a different
 * signature (the child closed PiP, left split, opened another app) starts a fresh budget.
 *
 * Pure by construction: no clock, no Android types, so the JVM suite pins the loop bound.
 */
class OverlayRetryBudget(private val maxAttempts: Int = DEFAULT_MAX_ATTEMPTS) {
    private var signature: String? = null
    private var attempts = 0
    private var exhaustedLogged = false

    fun attempt(signature: String): RetryDecision {
        if (signature != this.signature) {
            this.signature = signature
            attempts = 0
            exhaustedLogged = false
        }
        if (attempts >= maxAttempts) {
            if (exhaustedLogged) return RetryDecision.EXHAUSTED
            exhaustedLogged = true
            return RetryDecision.EXHAUSTED_ONCE
        }
        attempts++
        return RetryDecision.ATTEMPT
    }

    companion object {
        /** Three raises is enough for a transient layout change and short enough not to churn. */
        const val DEFAULT_MAX_ATTEMPTS: Int = 3
    }
}
