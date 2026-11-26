package com.familyshield.agent.enforcement

import android.content.Context
import com.familyshield.agent.security.TamperScreenPolicy

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

    /**
     * #1240 Ahmed R3 ([Sat]): hard deny-set that can NEVER bypass Lock via `alwaysAllowedApps`,
     * whatever the parent's list contains — Settings, OEM settings/security centers, package
     * installers, Play Store, and VPN dialogs (plus dynamic `CATEGORY_HOME` launchers from
     * [PackageFacts.homePackages]).
     */
    val LOCK_ALLOWLIST_DENIED_PACKAGES: Set<String> = TamperScreenPolicy.SYSTEM_PACKAGES + setOf(
        TamperScreenPolicy.VPN_DIALOG_PACKAGE,
        "com.samsung.android.settings",
        "com.coloros.safecenter",
        "com.oplus.safecenter",
        "com.oppo.safe",
        "com.vivo.permissionmanager",
        "com.huawei.systemmanager",
        "com.miui.packageinstaller",
        "com.oplus.appdetail",
        "com.android.vending",
    )

    /** True when [pkg] must never be granted a Lock exemption or shortcut through `alwaysAllowedApps`. */
    fun isLockAllowlistDenied(pkg: String?, homePackages: Set<String> = emptySet()): Boolean {
        val trimmed = pkg?.trim().orEmpty()
        if (trimmed.isEmpty()) return true
        return trimmed in LOCK_ALLOWLIST_DENIED_PACKAGES || trimmed in homePackages
    }

    /**
     * Whether [pkg] is a package the lock must never cover (issue #80, review of #83 F1), plus
     * parent-configured always-allowed apps when [alwaysAllowedPackages] is supplied (issue #1183)
     * — subject to [isLockAllowlistDenied] so Settings/installers/Play Store/launchers can never
     * become a door out of Lock (#1240 R3).
     */
    fun isExemptPackage(
        pkg: String?,
        facts: PackageFacts,
        alwaysAllowedPackages: Set<String> = emptySet(),
    ): Boolean {
        if (pkg.isNullOrBlank()) return false
        if (pkg in alwaysAllowedPackages && !isLockAllowlistDenied(pkg, facts.homePackages())) return true
        return isEmergencyOrSystemExempt(pkg, facts)
    }

    /** Emergency dialer, in-call UI and system UI only — never includes parent app allowlists. */
    private fun isEmergencyOrSystemExempt(pkg: String, facts: PackageFacts): Boolean {
        if (pkg in facts.dialerRoleHolders()) return true
        val lower = pkg.lowercase()
        // Boundary, not substring: `com.android.phonebook.game` is not `com.android.phone`.
        val named = EXEMPT_PREFIXES.any { lower == it || lower.startsWith("$it.") } ||
            lower.split('.').any { it in EXEMPT_SEGMENTS }
        return named && facts.isSystemApp(pkg)
    }

    fun isLockingMode(mode: String?): Boolean = mode != null && mode in LOCKING_MODES

    /** Whether seeing [foregroundPackage] on top while [mode] is active means the overlay must be re-raised. */
    fun shouldReraise(
        mode: String?,
        foregroundPackage: String?,
        ownPackage: String,
        facts: PackageFacts,
        alwaysAllowedPackages: Set<String> = emptySet(),
    ): Boolean {
        if (!isLockingMode(mode) || foregroundPackage.isNullOrBlank()) return false
        if (foregroundPackage == ownPackage) return false
        return !isExemptPackage(foregroundPackage, facts, alwaysAllowedPackages)
    }

    /**
     * Issue #175 + #1183: the multi-window form. A blocked app can be visible without being active —
     * in the other half of a split screen or in a picture-in-picture window over the launcher — and
     * the active-window-only check never brought the overlay back over it.
     *
     * Order matters:
     * 1. An active call / emergency surface is never covered, whatever else is visible (issue #80).
     * 2. An active app that is neither ours nor exempt (including non-denied [alwaysAllowedPackages])
     *    raises the overlay immediately.
     * 3. An active always-allowed app (#1183) stays uncovered ONLY if no non-exempt app is visible
     *    beside it in split screen or PiP — so an always-allowed app cannot be used to prop open a
     *    blocked app in the other half of the screen.
     * 4. Our own overlay in PiP is not coverage either: a PiP window floats above the app behind it,
     *    so the policy allows the service to replace (and expand) it. The service bounds that retry
     *    ([OverlayRetryBudget]) because the platform may refuse to leave PiP.
     */
    fun shouldReraise(
        mode: String?,
        snapshot: WindowSnapshot,
        ownPackage: String,
        facts: PackageFacts,
        alwaysAllowedPackages: Set<String> = emptySet(),
    ): Boolean {
        if (!isLockingMode(mode)) return false
        val active = snapshot.activePackage
        if (!active.isNullOrBlank() && active != ownPackage && isEmergencyOrSystemExempt(active, facts)) {
            return false
        }
        val activeAllowed = !active.isNullOrBlank() &&
            active != ownPackage &&
            active in alwaysAllowedPackages &&
            !isLockAllowlistDenied(active, facts.homePackages())
        if (!active.isNullOrBlank() && active != ownPackage && !activeAllowed) {
            return true
        }
        if (snapshot.windows.any { it.packageName == ownPackage && it.inPictureInPicture }) return true
        return snapshot.windows.any { window ->
            val pkg = window.packageName
            !pkg.isNullOrBlank() && pkg != ownPackage && !isExemptPackage(pkg, facts, alwaysAllowedPackages)
        }
    }

    /** Minimum gap between two re-raises, so a burst of window events does not start the activity repeatedly. */
    const val RERAISE_DEBOUNCE_MS: Long = 700
}
