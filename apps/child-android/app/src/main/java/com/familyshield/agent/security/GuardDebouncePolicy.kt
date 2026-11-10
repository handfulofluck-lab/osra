package com.familyshield.agent.security

/**
 * #533 review: when the tamper guard may skip a protection screen because the PIN gate already covers it.
 *
 * The old rule was "1.5 s since the last launch", checked before anything was classified. Once the gate
 * stopped sending a Back first, the guarded screen stayed alive behind it: Recents → Settings inside 1.5 s
 * brought the screen back, its one state change fell inside the debounce, and a static screen sends no more.
 * The rule now: suppress only while the gate is **in front**, or **still being launched** (inside the window
 * and not yet resumed since that launch). A gate that has come up and gone away never suppresses.
 *
 * [GuardGateState] supplies the two flags; `onPause` of the gate lands before the next activity resumes, so
 * a screen that returns over a paused gate always sees `gateShowing = false`.
 *
 * osra-security#7: in split screen both halves are resumed, so a gate in one half stayed "showing" while a
 * protection screen was opened and reopened in the other. Two more inputs now beat the flags: a gate in
 * multi-window mode covers nothing, so it never suppresses; and a window-state change from a window other
 * than the one last guarded is a new screen, judged even while the gate is up.
 */
object GuardDebouncePolicy {

    /** How long a launched gate is given to come up before the guard would launch it again. */
    const val LAUNCH_WINDOW_MS: Long = 1_500L

    fun suppress(
        nowMs: Long,
        lastGuardMs: Long,
        gateShowing: Boolean,
        gateResumedSinceLaunch: Boolean,
        gateMultiWindow: Boolean = false,
        newWindow: Boolean = false,
    ): Boolean {
        if (gateMultiWindow || newWindow) return false
        if (gateShowing) return true
        val launchPending = nowMs - lastGuardMs < LAUNCH_WINDOW_MS && !gateResumedSinceLaunch
        return launchPending
    }
}

/**
 * Process-wide state of the PIN gate, written by [TamperGuardActivity] and read by the accessibility service
 * (same process). Volatile because they are written on the main thread and read on the service's event thread.
 */
object GuardGateState {
    /** True between the gate's `onResume` and `onPause`. */
    @Volatile var showing: Boolean = false

    /** Wall-clock time of the gate's last `onResume`, 0 before the first. */
    @Volatile var lastResumedMs: Long = 0L

    /** osra-security#7: true while the gate is resumed in split screen, pop-up or freeform. */
    @Volatile var multiWindow: Boolean = false

    /** Whether the gate has come up since a launch at [launchMs]. */
    fun resumedSince(launchMs: Long): Boolean = lastResumedMs >= launchMs && lastResumedMs != 0L
}

/**
 * osra-security#7: what a gate that finds itself sharing the screen does. Only the guard's gate refuses, by going
 * Home: it is already the root of a non-resizeable task, so a relaunch would land on the same instance. An in-app
 * gate stays, because its caller needs the result and the action it protects runs only after the PIN.
 */
object GuardMultiWindowPolicy {
    fun goHome(guardGate: Boolean, inMultiWindow: Boolean): Boolean = guardGate && inMultiWindow
}
