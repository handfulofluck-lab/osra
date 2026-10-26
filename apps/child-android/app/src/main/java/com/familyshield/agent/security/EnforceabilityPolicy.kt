package com.familyshield.agent.security

import com.familyshield.agent.commands.CommandOutcome

/**
 * Issue #231 review (D1/D2): an ack may only say `ok` when the enforcement the command asks for can
 * actually take effect on this device. Before this, `lock()`/`pause()` returned `Applied()` after
 * `startActivity`, which does not fail when the OS blocks the background launch, and
 * `pauseInternet()` returned `Applied()` even with no VPN to filter the traffic — both told the
 * parent "done" while the phone did nothing (measured on the Flip4, 2026-10-20).
 *
 * The two lock paths, in the order the outcome names them:
 * - **overlay** — `Settings.canDrawOverlays` is granted. The holder of that app-op is exempt from the
 *   background-activity-launch rule, so the dispatcher's `startActivity` for `LockActivity` lands. On
 *   its own it shows our screen **once**: `LockActivity.onPause` deliberately does not re-raise itself
 *   (the emergency-dialer finding), so the child presses Home and the screen is gone.
 * - **accessibility** — our accessibility service is bound. It is exempt from the same rule and
 *   re-raises the overlay over the first non-exempt window from
 *   `AccessibilityMonitorService.enforceLockState`, which is what makes a lock *hold*. Without it
 *   neither path survives Home, so it is required for either one (ADR-0034).
 *
 * `lockNow()` (device admin) is **not** a path. It locks the child's own keyguard, shows nothing of
 * ours, and the child's unlock ends it — measured on the Flip4 on 24 Oct, where the parent was told
 * "locked" while the phone was usable and no OSRA screen could be launched. `adminLocked` stays in
 * the signature because the dispatcher still calls `lockNow()`: it is a belt with the other two, and
 * the ack's `via` never names it.
 *
 * `pause` has the same two paths and the same requirement: it must stay resumable by `resume`, so it
 * never calls `lockNow()`.
 *
 * ADR-0034 derives the capability report's `ready` for `lock_screen` and `pause_screen` from this
 * same predicate, so both are `ready` only while the accessibility service runs — an overlay-only
 * phone is neither `ready` nor `degraded`, because nothing re-raises the screen after Home.
 *
 * `unlock`/`resume` have no refusal: by the time the outcome is decided `LockState` is already
 * cleared, so nothing of ours is still supposed to be on screen. What the ack reports instead is
 * whether the lock/pause screen was actually up, `detail.screen = dismissed|not_showing` (issue
 * #233 review, F1 — a refused unlock was measured firing exactly when the unlock had worked, while
 * the parent was told the child's phone was still covered). There is no keyguard path on purpose:
 * `lockNow` is not involved and the child's keyguard is the human's, not ours.
 *
 * The dispatcher writes `LockState` **before** asking this policy, in every case, so the lock
 * applies the moment a grant returns. The ack is about now, not later.
 *
 * Pure Kotlin on purpose (no Android types): the JVM suite holds every row.
 */
object EnforceabilityPolicy {

    /** No path can show the lock/pause screen: overlay permission off and the service not bound. */
    const val REASON_LOCK_SCREEN_UNAVAILABLE = "lock_screen_unavailable"

    /** `pause_internet` asked for a filter the device never consented to, so no packet is dropped. */
    const val REASON_WEB_FILTER_NOT_SET_UP = "web_filter_not_set_up"

    /** The path that can actually make a `lock` visible; its wire value is the ack's `detail.via`. */
    enum class LockPath(val wire: String) {
        OVERLAY("overlay"),
        ACCESSIBILITY("accessibility"),
    }

    /** The path that can actually make a `pause` visible; its wire value is the ack's `detail.via`. */
    enum class PausePath(val wire: String) {
        OVERLAY("overlay"),
        ACCESSIBILITY("accessibility"),
    }

    /**
     * What the lock/pause screen was when an `unlock`/`resume` ran; its wire value is the ack's
     * `detail.screen`.
     */
    enum class UnlockScreen(val wire: String) {
        /** Our screen was up, so the dismiss launch was allowed and the screen is gone. */
        DISMISSED("dismissed"),

        /** Nothing of ours was on screen, so there was nothing to take down and no launch was made. */
        NOT_SHOWING("not_showing"),
    }

    /**
     * `Applied(via=…)` when a path can show **and hold** our lock screen; refused with
     * [REASON_LOCK_SCREEN_UNAVAILABLE] otherwise.
     *
     * Issue #368 (**ADR-0034**): a keyguard-only lock is not an applied lock — `lockNow()` locks the
     * child's own keyguard, nothing of ours appears, and the child's unlock ends it (Flip4, 24 Oct:
     * the parent was told "locked" while the phone was usable, `Background activity launch blocked`,
     * result 102).
     *
     * An **overlay-only** lock is not an applied lock either, for the same reason one step later:
     * `LockActivity.onPause` does not re-raise itself, so with the accessibility service off the
     * screen shows once, Home takes it away, and the ack has already said `ok`. Only
     * `AccessibilityMonitorService.enforceLockState` brings it back. So the service is required, and
     * `via` names the overlay when the app-op is also granted, because that is the path the
     * dispatcher starts and the service then re-raises.
     */
    fun lockOutcome(canOverlay: Boolean, accessibilityRunning: Boolean, adminLocked: Boolean): CommandOutcome =
        if (!accessibilityRunning) {
            CommandOutcome.Refused(REASON_LOCK_SCREEN_UNAVAILABLE)
        } else {
            CommandOutcome.Applied(detail = mapOf("via" to (if (canOverlay) LockPath.OVERLAY else LockPath.ACCESSIBILITY).wire))
        }

    /** The same rule for `pause`: applied only while the service can re-raise the screen; refused otherwise. */
    fun pauseOutcome(canOverlay: Boolean, accessibilityRunning: Boolean): CommandOutcome =
        if (!accessibilityRunning) {
            CommandOutcome.Refused(REASON_LOCK_SCREEN_UNAVAILABLE)
        } else {
            CommandOutcome.Applied(detail = mapOf("via" to (if (canOverlay) PausePath.OVERLAY else PausePath.ACCESSIBILITY).wire))
        }

    /**
     * Issue #233 review (F1): `unlock`/`resume` always applied — the only question the ack answers
     * is whether the lock/pause screen was up when the command ran, and that is
     * [UnlockScreen.DISMISSED] vs [UnlockScreen.NOT_SHOWING].
     *
     * A refusal would be a lie either way it fires: with our screen showing, the visible window
     * itself lets Android start `LockActivity` (`BAL_ALLOW_VISIBLE_WINDOW`) even with overlay and
     * accessibility off; with nothing showing there is nothing to take down and `LockState.clear`
     * has already dropped the pending lock. Measured on the Flip4: rows where the screen went away
     * were acked `failed unlock_screen_unavailable`, telling the parent the phone was still covered.
     *
     * There is no keyguard path: `unlock`/`resume` only take down our own full-screen overlay and
     * never call `lockNow()`. The child's keyguard is the human's lock screen, not ours
     * (`docs/TESTING.md` §5.0), and an agent must not attempt it.
     */
    fun unlockOutcome(lockScreenShowing: Boolean): CommandOutcome =
        CommandOutcome.Applied(
            detail = mapOf(
                "screen" to if (lockScreenShowing) UnlockScreen.DISMISSED.wire else UnlockScreen.NOT_SHOWING.wire,
            ),
        )

    /**
     * D2: `ok` means the filter can be running, not that the intent to pause was recorded.
     * [webFilterSetUp] is the caller's determination that both the stored consent and the OS
     * preparation are in place (`VpnState.isEnabled` alone stays true after the consent is revoked
     * in Settings, while `FilterVpnService.start` silently returns). The caller persists the paused
     * state either way, so the pause applies when the filter is set up.
     */
    fun pauseInternetOutcome(webFilterSetUp: Boolean): CommandOutcome =
        if (webFilterSetUp) {
            CommandOutcome.Applied()
        } else {
            CommandOutcome.Refused(REASON_WEB_FILTER_NOT_SET_UP)
        }
}
