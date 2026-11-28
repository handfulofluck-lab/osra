package com.familyshield.agent.recovery

/**
 * Pure policy for post-exit fast revival and standing non-wakeup watchdog recovery (osra-security#78).
 *
 * Two bounded paths cover process termination without risking a hot wake loop:
 * 1. **Exit-callback fast revival ([evaluateExitRevival]):** schedules a `1.5 s` wakeup when an
 *    active paired service exits unexpectedly, capped at [MAX_REVIVALS_PER_WINDOW] (`3`) attempts per
 *    [REVIVAL_WINDOW_MS] (`10 minutes`). Attempt #4 inside the same window returns `schedule = false`
 *    and sets `capReachedNow = true` once so the caller logs the cap and defers to periodic recovery.
 * 2. **Standing non-wakeup watchdog ([shouldKeepStandingWatchdog], [standingWatchdogDelayMs]):**
 *    pre-arms an `AlarmManager.ELAPSED_REALTIME` (non-wakeup) check while paired and active so even a
 *    raw kernel `SIGKILL` (`am_kill ... OneKeyClean`, where `onTaskRemoved` / `onDestroy` never run)
 *    recovers within [STANDING_WATCHDOG_MS] (`60 s`) while the phone is interactive, with zero wakeup
 *    cost while sleeping and automatic `10-minute` backoff if [MAX_REVIVALS_PER_WINDOW] recoveries
 *    already fired in the current window.
 */
object ServiceRevivalPolicy {

    /** Delay before the fast `AlarmManager` revival broadcast fires after service teardown. */
    const val REVIVAL_DELAY_MS: Long = 1_500L

    /** Normal interval for the standing non-wakeup `ELAPSED_REALTIME` watchdog while paired. */
    const val STANDING_WATCHDOG_MS: Long = 60_000L

    /** Sliding monotonic window (`10 minutes`) bounding fast/standing service revivals. */
    const val REVIVAL_WINDOW_MS: Long = 10L * 60L * 1000L

    /** Maximum revivals permitted within [REVIVAL_WINDOW_MS] before fast revival stands down. */
    const val MAX_REVIVALS_PER_WINDOW: Int = 3

    const val NO_BOOT: Int = -1

    const val ACTION_REVIVE_SERVICES: String = "com.familyshield.agent.action.REVIVE_SERVICES"
    const val ACTION_STANDING_WATCHDOG: String = "com.familyshield.agent.action.STANDING_WATCHDOG"

    data class WindowState(
        val windowStartElapsedMs: Long = 0L,
        val attemptCount: Int = 0,
        val capLogged: Boolean = false,
        val bootCount: Int = NO_BOOT,
    )

    data class ExitRevivalDecision(
        val schedule: Boolean,
        val nextState: WindowState,
        val capReachedNow: Boolean,
    )

    fun normalizedWindow(
        state: WindowState,
        nowElapsedMs: Long,
        bootCount: Int = NO_BOOT,
    ): WindowState {
        val bootChanged = bootCount != NO_BOOT && state.bootCount != NO_BOOT && bootCount != state.bootCount
        val clockReset = state.windowStartElapsedMs > 0L && nowElapsedMs < state.windowStartElapsedMs
        val expired = state.windowStartElapsedMs <= 0L ||
            state.attemptCount <= 0 ||
            (nowElapsedMs - state.windowStartElapsedMs) >= REVIVAL_WINDOW_MS
        return if (bootChanged || clockReset || expired) {
            WindowState(bootCount = bootCount)
        } else if (state.bootCount == NO_BOOT && bootCount != NO_BOOT) {
            state.copy(bootCount = bootCount)
        } else {
            state
        }
    }

    fun shouldScheduleOnServiceExit(
        paired: Boolean,
        consentPaused: Boolean,
        unlinkPending: Boolean = false,
        explicitlyStopping: Boolean = false,
        attemptCountInWindow: Int = 0,
    ): Boolean =
        paired &&
            !consentPaused &&
            !unlinkPending &&
            !explicitlyStopping &&
            attemptCountInWindow < MAX_REVIVALS_PER_WINDOW

    fun evaluateExitRevival(
        paired: Boolean,
        consentPaused: Boolean,
        unlinkPending: Boolean = false,
        explicitlyStopping: Boolean = false,
        nowElapsedMs: Long,
        current: WindowState = WindowState(),
        bootCount: Int = NO_BOOT,
    ): ExitRevivalDecision {
        val active = normalizedWindow(current, nowElapsedMs, bootCount)
        if (!paired || consentPaused || unlinkPending || explicitlyStopping) {
            return ExitRevivalDecision(schedule = false, nextState = active, capReachedNow = false)
        }
        if (active.attemptCount >= MAX_REVIVALS_PER_WINDOW) {
            return ExitRevivalDecision(
                schedule = false,
                nextState = active.copy(capLogged = true),
                capReachedNow = !active.capLogged,
            )
        }
        val windowStart = if (active.attemptCount == 0) nowElapsedMs else active.windowStartElapsedMs
        return ExitRevivalDecision(
            schedule = true,
            nextState = WindowState(
                windowStartElapsedMs = windowStart,
                attemptCount = active.attemptCount + 1,
                capLogged = false,
                bootCount = bootCount,
            ),
            capReachedNow = false,
        )
    }

    fun shouldKeepStandingWatchdog(
        paired: Boolean,
        consentPaused: Boolean,
        unlinkPending: Boolean = false,
    ): Boolean = paired && !consentPaused && !unlinkPending

    /**
     * Records a standing-watchdog tick. Healthy ticks (`planEmpty == true`) consume zero attempts;
     * ticks that actually restarted a dead service increment the window count so repeated crash/kill
     * loops back off to [REVIVAL_WINDOW_MS].
     */
    fun recordStandingRecovery(
        current: WindowState,
        planEmpty: Boolean,
        nowElapsedMs: Long,
        bootCount: Int = NO_BOOT,
    ): WindowState {
        val active = normalizedWindow(current, nowElapsedMs, bootCount)
        if (planEmpty) return active
        val windowStart = if (active.attemptCount == 0) nowElapsedMs else active.windowStartElapsedMs
        val nextCount = active.attemptCount + 1
        return WindowState(
            windowStartElapsedMs = windowStart,
            attemptCount = nextCount,
            capLogged = active.capLogged || nextCount > MAX_REVIVALS_PER_WINDOW,
            bootCount = bootCount,
        )
    }

    fun standingWatchdogDelayMs(
        state: WindowState,
        nowElapsedMs: Long,
        bootCount: Int = NO_BOOT,
    ): Long {
        val active = normalizedWindow(state, nowElapsedMs, bootCount)
        return if (active.attemptCount >= MAX_REVIVALS_PER_WINDOW) {
            REVIVAL_WINDOW_MS
        } else {
            STANDING_WATCHDOG_MS
        }
    }

    fun shouldRunStartupRecovery(unlinkPending: Boolean): Boolean = !unlinkPending
}
