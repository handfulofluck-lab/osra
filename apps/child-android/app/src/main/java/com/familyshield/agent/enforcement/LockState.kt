package com.familyshield.agent.enforcement

import android.content.Context

/**
 * Persisted "what should be on the screen right now" for the parent's lock / pause commands
 * (plan item 1.3, ADR-0010 §5). Before this the overlay's mode lived only in the activity: a swipe
 * from Recents or a reboot cleared it and the child was back in their apps until the next command.
 * Now the dispatcher records the mode here, the accessibility service re-raises the overlay whenever
 * another window comes to the front, and the boot receiver re-applies it after a restart.
 *
 * A boolean-ish string in plain SharedPreferences — not a secret, and it must be readable from a
 * receiver before any encrypted store is open.
 */
object LockState {
    const val MODE_NONE = "none"
    private const val PREFS = "osra_lock_state"
    private const val KEY_MODE = "mode"
    private const val KEY_SINCE = "since_ms"

    fun set(context: Context, mode: String, nowMs: Long = System.currentTimeMillis()) {
        prefs(context).edit().putString(KEY_MODE, mode).putLong(KEY_SINCE, nowMs).apply()
    }

    fun clear(context: Context) {
        prefs(context).edit().putString(KEY_MODE, MODE_NONE).remove(KEY_SINCE).apply()
    }

    fun mode(context: Context): String = prefs(context).getString(KEY_MODE, MODE_NONE) ?: MODE_NONE

    fun isActive(context: Context): Boolean = LockEnforcementPolicy.isLockingMode(mode(context))

    private fun prefs(context: Context) = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
}

/**
 * Pure rules for re-raising the overlay (JVM-tested). The overlay must come back over anything the
 * child opens — the launcher, Recents, Settings, another app — but never over a phone call or the
 * emergency dialer, and never over our own windows (that would loop).
 */
object LockEnforcementPolicy {
    private val LOCKING_MODES = setOf("locked", "paused", "paused_internet")

    /**
     * Packages the lock must never cover: in-call UI, the emergency dialer, the system UI itself.
     *
     * Issue #80: the Flip4's emergency dialer is `com.samsung.android.emergency`, and this list only
     * had AOSP's `com.android.emergency`, so the overlay covered the dialer on the one device we test
     * while the unit test passed. The first fix matched the package name and the *segment*
     * (`*.emergency`, `*.incallui`, `*.dialer`), which kept every OEM reachable — and handed a lock
     * bypass to anyone who published `com.anything.dialer` (review of #83, F1).
     *
     * The rule is now about what the OS says a package is, not what it is called:
     *   1. a **dialer role holder** is always exempt (`TelecomManager` defaults plus the system
     *      handlers of the emergency-dialer and `ACTION_DIAL` intents) — the OS assigned that role;
     *   2. otherwise a name is only a hint: the prefix/segment table still applies, but **only when
     *      the package is a system app**. A sideloaded `com.example.dialer` is a game with a name.
     * The asymmetry is deliberate: over-exempting a real dialer costs one unlocked app, blocking an
     * emergency call costs the call.
     */
    private val EXEMPT_PREFIXES = listOf(
        "com.android.incallui",
        "com.samsung.android.incallui",
        "com.google.android.incallui",
        "com.google.android.dialer",
        "com.android.dialer",
        "com.samsung.android.dialer",
        "com.android.emergency",
        "com.samsung.android.emergency",
        "com.google.android.emergency",
        "com.android.systemui",
        "com.android.phone",
        "com.samsung.android.phone",
    )

    /** Segments that name an emergency/call surface in any OEM's package namespace. */
    private val EXEMPT_SEGMENTS = setOf("emergency", "incallui", "dialer")

    /** Whether [pkg] is a package the lock must never cover (issue #80, review of #83 F1). */
    fun isExemptPackage(pkg: String?, facts: PackageFacts): Boolean {
        if (pkg.isNullOrBlank()) return false
        if (pkg in facts.dialerRoleHolders()) return true
        val lower = pkg.lowercase()
        // Boundary, not substring: `com.android.phonebook.game` is not `com.android.phone`.
        val named = EXEMPT_PREFIXES.any { lower == it || lower.startsWith("$it.") } ||
            lower.split('.').any { it in EXEMPT_SEGMENTS }
        return named && facts.isSystemApp(pkg)
    }

    fun isLockingMode(mode: String?): Boolean = mode != null && mode in LOCKING_MODES

    /** Whether seeing [foregroundPackage] on top while [mode] is active means the overlay must be re-raised. */
    fun shouldReraise(mode: String?, foregroundPackage: String?, ownPackage: String, facts: PackageFacts): Boolean {
        if (!isLockingMode(mode) || foregroundPackage.isNullOrBlank()) return false
        if (foregroundPackage == ownPackage) return false
        return !isExemptPackage(foregroundPackage, facts)
    }

    /**
     * Issue #175: the multi-window form. A blocked app can be visible without being active — in the
     * other half of a split screen or in a picture-in-picture window over the launcher — and the
     * active-window-only check never brought the overlay back over it.
     *
     * Order matters:
     * 1. An active call surface is never covered, whatever else is visible (issue #80).
     * 2. Any other visible window that is not ours and not exempt means the overlay is not covering
     *    the screen, whether it is active, beside us, or floating in PiP.
     * 3. Our own overlay in PiP is not coverage either: a PiP window floats above the app behind it,
     *    so the policy allows the service to replace (and expand) it. The service bounds that retry
     *    ([OverlayRetryBudget]) because the platform may refuse to leave PiP.
     */
    fun shouldReraise(
        mode: String?,
        snapshot: WindowSnapshot,
        ownPackage: String,
        facts: PackageFacts,
    ): Boolean {
        if (!isLockingMode(mode)) return false
        val active = snapshot.activePackage
        if (!active.isNullOrBlank() && active != ownPackage && isExemptPackage(active, facts)) return false
        if (!active.isNullOrBlank() && active != ownPackage) return true
        if (snapshot.windows.any { it.packageName == ownPackage && it.inPictureInPicture }) return true
        return snapshot.windows.any { window ->
            val pkg = window.packageName
            !pkg.isNullOrBlank() && pkg != ownPackage && !isExemptPackage(pkg, facts)
        }
    }

    /** Minimum gap between two re-raises, so a burst of window events does not start the activity repeatedly. */
    const val RERAISE_DEBOUNCE_MS: Long = 700
}
