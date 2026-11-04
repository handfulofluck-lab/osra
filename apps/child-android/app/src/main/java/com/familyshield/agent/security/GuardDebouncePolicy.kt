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
 */
object GuardDebouncePolicy {

    /** How long a launched gate is given to come up before the guard would launch it again. */
    const val LAUNCH_WINDOW_MS: Long = 1_500L

    fun suppress(nowMs: Long, lastGuardMs: Long, gateShowing: Boolean, gateResumedSinceLaunch: Boolean): Boolean {
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

    /** Whether the gate has come up since a launch at [launchMs]. */
    fun resumedSince(launchMs: Long): Boolean = lastResumedMs >= launchMs && lastResumedMs != 0L
}
