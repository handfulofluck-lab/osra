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
     * Two mechanisms, because OEMs rename these freely and a missed name means a child cannot call for
     * help. Issue #80: the Flip4's emergency dialer is `com.samsung.android.emergency`, and this list
     * only had AOSP's `com.android.emergency` — so the overlay covered the dialer on the one device we
     * test, while the unit test passed.
     *   1. the explicit prefixes below, for the packages we have actually seen;
     *   2. a **segment** match (`*.emergency`, `*.incallui`, `*.dialer`), so an OEM we have not seen
     *      still gets through.
     * The asymmetry is deliberate: over-exempting a dialer costs one unlocked app, blocking an
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

    /** Whether [pkg] is a package the lock must never cover (issue #80). */
    fun isExemptPackage(pkg: String?): Boolean {
        if (pkg.isNullOrBlank()) return false
        val lower = pkg.lowercase()
        if (EXEMPT_PREFIXES.any { lower.startsWith(it) }) return true
        // Segment equality, not substring: `com.example.emergencygame` is a game, not a dialer.
        return lower.split('.').any { it in EXEMPT_SEGMENTS }
    }

    fun isLockingMode(mode: String?): Boolean = mode != null && mode in LOCKING_MODES

    /** Whether seeing [foregroundPackage] on top while [mode] is active means the overlay must be re-raised. */
    fun shouldReraise(mode: String?, foregroundPackage: String?, ownPackage: String): Boolean {
        if (!isLockingMode(mode) || foregroundPackage.isNullOrBlank()) return false
        if (foregroundPackage == ownPackage) return false
        return !isExemptPackage(foregroundPackage)
    }

    /** Minimum gap between two re-raises, so a burst of window events does not start the activity repeatedly. */
    const val RERAISE_DEBOUNCE_MS: Long = 700
}
