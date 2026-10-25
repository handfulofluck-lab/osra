package com.familyshield.agent.security

import com.familyshield.agent.commands.CommandOutcome

/**
 * Issue #231 review (D1/D2): an ack may only say `ok` when the enforcement the command asks for can
 * actually take effect on this device. Before this, `lock()`/`pause()` returned `Applied()` after
 * `startActivity`, which does not fail when the OS blocks the background launch, and
 * `pauseInternet()` returned `Applied()` even with no VPN to filter the traffic — both told the
 * parent "done" while the phone did nothing (measured on the Flip4, 2026-10-20).
 *
 * The three lock paths, in the order the outcome names them:
 * - **keyguard** — `DevicePolicyManager.lockNow()` returned true (device admin/owner). The screen is
 *   locked even if the overlay cannot be launched.
 * - **overlay** — `Settings.canDrawOverlays` is granted. The holder of that app-op is exempt from the
 *   background-activity-launch rule, so the dispatcher's `startActivity` for `LockActivity` lands.
 * - **accessibility** — our accessibility service is bound. It is exempt from the same rule and
 *   re-raises the overlay over the first non-exempt window, so the lock applies even without overlay.
 *
 * `pause` has no keyguard path on purpose: it must stay resumable by `resume`, so it never calls
 * `lockNow()`. Its viable paths are the overlay and the accessibility service.
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
        KEYGUARD("keyguard"),
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
     * `Applied(via=…)` when a path can show **our** lock screen; refused with
     * [REASON_LOCK_SCREEN_UNAVAILABLE] otherwise.
     *
     * Issue #368 (**ADR-0034**): a keyguard-only lock is **not** an applied lock. `lockNow()` does
     * lock the screen, but nothing of ours appears, and the Flip4 measurement on 24 Oct showed the
     * child's own unlock ends it — the parent was told "locked" while the phone was usable and no
     * OSRA screen could be launched (`Background activity launch blocked`, result 102). So the
     * keyguard alone no longer makes this an `Applied`: the overlay or the accessibility service has
     * to be there. `adminLocked` is kept in the signature because the dispatcher still calls
     * `lockNow()` on that path — it is a useful belt with `overlay`/`accessibility`, and the ack's
     * `via` names whichever of those two existed.
     */
    fun lockOutcome(canOverlay: Boolean, accessibilityRunning: Boolean, adminLocked: Boolean): CommandOutcome =
        when {
            canOverlay -> CommandOutcome.Applied(detail = mapOf("via" to LockPath.OVERLAY.wire))
            accessibilityRunning -> CommandOutcome.Applied(detail = mapOf("via" to LockPath.ACCESSIBILITY.wire))
            else -> CommandOutcome.Refused(REASON_LOCK_SCREEN_UNAVAILABLE)
        }

    /** `Applied(via=…)` when the pause screen can appear; refused with the same reason as `lock`. */
    fun pauseOutcome(canOverlay: Boolean, accessibilityRunning: Boolean): CommandOutcome =
        when {
            canOverlay -> CommandOutcome.Applied(detail = mapOf("via" to PausePath.OVERLAY.wire))
            accessibilityRunning -> CommandOutcome.Applied(detail = mapOf("via" to PausePath.ACCESSIBILITY.wire))
            else -> CommandOutcome.Refused(REASON_LOCK_SCREEN_UNAVAILABLE)
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
