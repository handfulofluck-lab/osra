package com.familyshield.agent.security

/**
 * Pure decision table for the Android tamper-protection layer (ADR-0010), free of Android types so
 * it is unit-testable. It answers two questions the UI and the admin receiver ask:
 *
 *  - which protection level the agent currently has, given what the OS granted; and
 *  - whether a protection-removal action (disable admin, re-pair, stop lock) may proceed.
 *
 * The device can be in one of three enforcement tiers. Which one is reached depends on how the agent
 * was provisioned — a normal sideload reaches ADMIN at best; a `dpm set-device-owner` or an EMM
 * enrolment reaches OWNER.
 */
enum class ProtectionTier {
    /** No Device Admin: the child can uninstall or force-stop freely. Alert the parent. */
    NONE,

    /** Active Device Admin: disabling admin or uninstalling first requires clearing admin, which we
     *  gate behind the parent PIN and alert on. Lock uses an overlay. */
    ADMIN,

    /** Device Owner / profile owner: uninstall is blocked outright (`setUninstallBlocked`), lock uses
     *  lock-task / `lockNow`, and the app cannot be removed without clearing the owner. */
    OWNER,
}

/** A protection-removal action the child (or anyone) can attempt on the device. */
enum class ProtectedAction { DISABLE_ADMIN, RE_PAIR, STOP_LOCK }

object TamperPolicy {

    /** The tier implied by what the OS reports. Owner implies admin. */
    fun tierOf(isAdminActive: Boolean, isDeviceOwner: Boolean): ProtectionTier = when {
        isDeviceOwner -> ProtectionTier.OWNER
        isAdminActive -> ProtectionTier.ADMIN
        else -> ProtectionTier.NONE
    }

    /**
     * Whether a protection-removal [action] may proceed given whether a parent PIN is configured and
     * whether the entered PIN was correct.
     *
     * The rule is deliberately strict: once a PIN exists, every removal action requires it. Before a
     * PIN is ever set (fresh pairing, legacy installs) removal is allowed so the agent can never lock
     * a family out of their own device — but pairing sets a PIN, so that window is the setup screen only.
     */
    fun removalAllowed(action: ProtectedAction, pinConfigured: Boolean, pinVerified: Boolean): Boolean =
        !pinConfigured || pinVerified

    /** True when the current tier should raise a tamper alert to the parent (admin missing/just removed). */
    fun shouldAlertOnTier(previous: ProtectionTier, current: ProtectionTier): Boolean =
        current == ProtectionTier.NONE && previous != ProtectionTier.NONE

    /** Whether uninstall is blocked outright by the OS (owner only); ADMIN relies on the PIN + alert. */
    fun uninstallBlockedByOs(tier: ProtectionTier): Boolean = tier == ProtectionTier.OWNER
}
