package com.familyshield.agent.enforcement

/**
 * The packages the **app-block overlay** ([BlockActivity]) must never cover: the launcher, the system
 * UI, the call surfaces (dialers, the emergency dialer, in-call UI, telephony) and the agent itself.
 *
 * Issue #165: before this, only the fail-closed path ([com.familyshield.agent.data.RuleRepository])
 * knew about essential packages, and the rules path did not. A bedtime rule is evaluated for whatever
 * is in the foreground, so it answered BLOCK for the home screen and the overlay followed the launcher
 * — the child could not press Home, reach the dialer, or be told what would still work. The set now
 * lives in one place and every path that can raise [BlockActivity] consults it:
 *
 * - [com.familyshield.agent.data.RuleRepository.evaluate] answers ALLOW for these packages before any
 *   rule (bedtime, allow-list, school, pause, blocklist, screen time) is consulted;
 * - [AppBlocker] re-checks with [PackageFacts], which also covers the packages only the OS can name:
 *   the current HOME handler and a system dialer the table has not seen yet.
 *
 * This is the same stance as the lock's exemption (`LockEnforcementPolicy`): over-exempting a real
 * launcher or dialer costs one reachable screen, covering one costs the child the phone. It is *not*
 * the lock: `LockEnforcementPolicy` deliberately still re-raises the lock over the launcher, and its
 * tests pin that.
 */
object EssentialPackages {

    /**
     * Exact package names. A name here is exempt without asking the OS, because the JVM rule path has
     * no `PackageManager`. Names are OEM-specific by nature; [isEssential] with [PackageFacts] adds the
     * OS-assigned HOME/dialer roles and a system-gated fallback for names this table does not know.
     */
    val EXACT: Set<String> = setOf(
        "com.familyshield.agent",
        "com.android.systemui",
        "com.android.settings",
        "com.android.phone",
        "com.android.server.telecom",
        "com.samsung.android.phone",
        "com.android.dialer",
        "com.google.android.dialer",
        "com.samsung.android.dialer",
        "com.android.emergency",
        "com.google.android.emergency",
        "com.samsung.android.emergency",
        "com.android.incallui",
        "com.google.android.incallui",
        "com.samsung.android.incallui",
        "com.android.launcher3",
        "com.google.android.apps.nexuslauncher",
        "com.sec.android.app.launcher",
    )

    private const val OWN_PREFIX = "com.familyshield."

    /**
     * True when [packageId] is on the static essential set (or is one of the agent's own packages).
     *
     * NOTE: a name is a *hint* here, not a role. `com.anything.dialer` is NOT exempt by name — review
     * of #83 (F1) established that a name the child can choose must not buy an exemption. The
     * system-gated segment match lives in [isEssential] with [PackageFacts].
     */
    fun isEssential(packageId: String?): Boolean {
        if (packageId.isNullOrBlank()) return false
        return packageId in EXACT || packageId.startsWith(OWN_PREFIX)
    }

    /**
     * OS-aware form used on the hot path: the static set above, the package that currently holds the
     * HOME role (whatever it is called), and the call surfaces the OS itself assigned — the default
     * dialer, the emergency-dialer / `ACTION_DIAL` handlers, and the name hints that are system apps.
     *
     * A HOME handler is exempt unconditionally, even one the user installed: blocking it would leave
     * the device with no home screen and the overlay with nowhere to send "Exit to Home screen".
     */
    fun isEssential(packageId: String?, facts: PackageFacts): Boolean {
        if (packageId.isNullOrBlank()) return false
        if (isEssential(packageId)) return true
        if (packageId in facts.homePackages()) return true
        return LockEnforcementPolicy.isExemptPackage(packageId, facts)
    }
}
