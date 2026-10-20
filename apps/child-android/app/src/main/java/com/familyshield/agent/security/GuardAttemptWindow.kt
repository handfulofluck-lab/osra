package com.familyshield.agent.security

/**
 * Issue #227: repeated attempts to open a protection-removal screen are one alert per window, with a
 * count. Five attempts 10 s apart used to be five critical pages; the parent now sees one row that
 * says five.
 *
 * The window is identified by its persisted start time and nothing else. It is deliberately **not**
 * keyed on the guard overlay becoming visible or the removal screen closing again: the child drives
 * both transitions, so a visibility-keyed window would reset on every retry and page every time.
 * [WINDOW_MS] matches the five minutes in the issue.
 *
 * The rule lives here, free of Android types, because the service and the worker cannot run in a JVM
 * test. The count is persisted before the POST so a failed POST cannot lose an attempt: the next
 * attempt carries the cumulative number.
 */
object GuardAttemptWindow {

    /** One alert window. The first attempt opens it; later attempts increment [count]. */
    const val WINDOW_MS: Long = 5 * 60_000L

    data class State(val windowStartMs: Long, val count: Int)

    /** [state] is the state to persist; [opensWindow] is true when this attempt starts a new alert. */
    data class Attempt(val state: State, val opensWindow: Boolean)

    /**
     * Folds one attempt at [nowMs] into [state], or opens a window when there is none, the previous
     * one is at least [WINDOW_MS] old, or the clock went backwards past its start.
     *
     * An attempt exactly at `windowStart + WINDOW_MS` belongs to the **new** window, so a five-minute
     * window covers `[start, start + WINDOW_MS)`. A backwards clock cannot reset the window (which
     * would page for each attempt); it keeps incrementing the current one.
     */
    fun record(state: State?, nowMs: Long): Attempt {
        if (state == null || nowMs < state.windowStartMs || nowMs - state.windowStartMs >= WINDOW_MS) {
            return Attempt(State(windowStartMs = nowMs, count = 1), opensWindow = true)
        }
        return Attempt(state.copy(count = state.count + 1), opensWindow = false)
    }
}
