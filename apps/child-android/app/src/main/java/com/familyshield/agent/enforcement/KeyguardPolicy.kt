package com.familyshield.agent.enforcement

/**
 * Whether the lock/pause overlay must step back and let the OS keyguard own the screen (issue #87).
 *
 * Why this is a rule and not a flag on the activity: `lock` is a real `lockNow()` (ADR-0010), so the
 * keyguard is up on every locked device. `LockActivity` used to draw over it (`FLAG_SHOW_WHEN_LOCKED`),
 * and on 2026-10-17 a `pause` sent while the bouncer was up put the overlay in front of it: the owner
 * could not enter their own PIN and the only recovery was `resume` from the server. The asymmetry is
 * the same one accepted for the emergency dialer — an owner locked out of their own device costs more
 * than a child seeing the keyguard before the parent's message.
 *
 * The mode survives in [LockState], so nothing is lost: the accessibility service re-raises the overlay
 * over the first non-exempt window after the keyguard is gone.
 *
 * Pure on purpose (JVM-tested): the two modes that must run while the keyguard is up are the ones that
 * *end* the lock — `unlock` (requests the keyguard dismissal) and `dismiss` (tears the overlay down).
 */
object KeyguardPolicy {
    /** `LockActivity.MODE_UNLOCK`: must execute so it can call `requestDismissKeyguard`. */
    private const val MODE_UNLOCK = "unlock"

    /** `LockActivity.MODE_DISMISS`: only finishes the activity, never draws. */
    private const val MODE_DISMISS = "dismiss"

    /**
     * Whether an overlay in [mode] must finish instead of drawing while the keyguard is up.
     * A null or blank mode is treated as the locked overlay (the activity's default).
     */
    fun shouldDeferToKeyguard(mode: String?, keyguardLocked: Boolean): Boolean {
        if (!keyguardLocked) return false
        return mode != MODE_UNLOCK && mode != MODE_DISMISS
    }
}
