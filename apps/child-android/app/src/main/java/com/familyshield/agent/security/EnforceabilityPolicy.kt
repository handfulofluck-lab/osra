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
 * `unlock`/`resume` have no keyguard path either: they dismiss our overlay, and `lockNow` is not
 * involved (there is nothing to "unlock" at the OS level — the keyguard belongs to the human, and
 * `docs/TESTING.md` §5.0 forbids an agent touching it). Their viable paths are the same overlay and
 * accessibility service, with their own refusal reason.
 *
 * The dispatcher writes `LockState` **before** asking this policy, in every case — including the
 * refusal — so the lock applies the moment a grant returns. The ack is about now, not later.
 *
 * Pure Kotlin on purpose (no Android types): the JVM suite holds every row.
 */
object EnforceabilityPolicy {

    /** No path can show the lock/pause screen: overlay permission off and the service not bound. */
    const val REASON_LOCK_SCREEN_UNAVAILABLE = "lock_screen_unavailable"

    /**
     * Neither the overlay nor accessibility can dismiss the overlay: `unlock`/`resume` were recorded,
     * but the screen stays up until a grant returns.
     */
    const val REASON_UNLOCK_SCREEN_UNAVAILABLE = "unlock_screen_unavailable"

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

    /** The path that can actually dismiss the overlay; its wire value is the ack's `detail.via`. */
    enum class UnlockPath(val wire: String) {
        OVERLAY("overlay"),
        ACCESSIBILITY("accessibility"),
    }

    /**
     * `Applied(via=…)` when at least one path can lock; refused with
     * [REASON_LOCK_SCREEN_UNAVAILABLE] otherwise. Precedence follows certainty, not cost: a keyguard
     * lock is the strongest effect, then the overlay the dispatcher can start itself, then the
     * event-driven re-raise.
     */
    fun lockOutcome(canOverlay: Boolean, accessibilityRunning: Boolean, adminLocked: Boolean): CommandOutcome =
        when {
            adminLocked -> CommandOutcome.Applied(detail = mapOf("via" to LockPath.KEYGUARD.wire))
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
     * Issue #233: `Applied(via=…)` when the overlay can actually be dismissed — the overlay app-op
     * or the accessibility service, the same two paths [pauseOutcome] accepts. Refused with
     * [REASON_UNLOCK_SCREEN_UNAVAILABLE] otherwise.
     *
     * There is no keyguard path: `unlock`/`resume` only take down our own full-screen overlay and
     * never call `lockNow()`, so the `adminLocked` argument [lockOutcome] takes has nothing to
     * decide here. The child's keyguard is the human's lock screen, not ours
     * (`docs/TESTING.md` §5.0), and an agent must not attempt it.
     */
    fun unlockOutcome(canOverlay: Boolean, accessibilityRunning: Boolean): CommandOutcome =
        when {
            canOverlay -> CommandOutcome.Applied(detail = mapOf("via" to UnlockPath.OVERLAY.wire))
            accessibilityRunning -> CommandOutcome.Applied(detail = mapOf("via" to UnlockPath.ACCESSIBILITY.wire))
            else -> CommandOutcome.Refused(REASON_UNLOCK_SCREEN_UNAVAILABLE)
        }

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
