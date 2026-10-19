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
 *
 * **Issue #192: the set is explicit, never a namespace prefix.** Until this fix the agent's own name
 * was matched with `startsWith("com.familyshield.")`, so any package in that namespace — including a
 * sideloaded `com.familyshield.notanapp` — was exempt from every block rule. Package names are global
 * only by convention. [OWN_PACKAGE] is the one package this app is built under; every component it
 * legitimately fronts lives in it (see below), so exactly one name is exempt.
 *
 * **Reopened 2026-10-19: the set was right, its input was wrong.** On the Flip4 (Android 16, WM-Shell)
 * the Home transition arrives as an accessibility event whose `packageName` is [FRAMEWORK_PACKAGE],
 * not the launcher's, so the decision asked this set about `android` — a name it must not contain —
 * and the overlay covered the launcher (`C:\KARIM\tr-kimi\hw-2026-10-19\RESULTS-165.md`). The package
 * a decision is made from is now resolved from the window actually in front by [foregroundPackage],
 * with the event's package only as a hint. Do **not** add [FRAMEWORK_PACKAGE] to [EXACT]: the framework
 * package fronts dialogs and other shell surfaces, so that would exempt far more than Home.
 */
object EssentialPackages {

    /**
     * The Android framework package. Accessibility events that belong to no app — the WM-Shell Home
     * transition is one — are reported under it, so it names a *window kind*, never a blockable app.
     */
    const val FRAMEWORK_PACKAGE: String = "android"

    /**
     * The agent's own application package (`applicationId` in `app/build.gradle.kts`, shared by the
     * `play` and `full` flavours).
     *
     * Android has no per-component package: every window the agent legitimately fronts is this one
     * package. The surfaces, all declared in `app/src/main/AndroidManifest.xml` (plus the Full-only
     * notification listener in `app/src/full/AndroidManifest.xml`), are the overlay and lock activities
     * ([com.familyshield.agent.enforcement.BlockActivity],
     * [com.familyshield.agent.commands.LockActivity], [com.familyshield.agent.commands.RingActivity]),
     * SOS ([com.familyshield.agent.sos.SosActivity]), the tamper guard
     * ([com.familyshield.agent.security.TamperGuardActivity]), pairing
     * ([com.familyshield.agent.setup.PairingActivity],
     * [com.familyshield.agent.setup.PairQrScanActivity]), and the services/receivers the OS starts
     * (`AccessibilityMonitorService`, `LocationService`, `FilterVpnService`, `BootReceiver`, …).
     *
     * Issue #192: this is an explicit allow-list entry, not a namespace prefix. Do not replace it with
     * a `startsWith` / shorter-string test and do not add a sibling `com.familyshield.*` name unless it
     * is actually ours: the Full build is sideloaded, so a child can install a package called
     * `com.familyshield.notanapp`.
     */
    const val OWN_PACKAGE: String = "com.familyshield.agent"

    /**
     * Exact package names. A name here is exempt without asking the OS, because the JVM rule path has
     * no `PackageManager`. Names are OEM-specific by nature; [isEssential] with [PackageFacts] adds the
     * OS-assigned HOME/dialer roles and a system-gated fallback for names this table does not know.
     */
    val EXACT: Set<String> = setOf(
        OWN_PACKAGE,
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

    /**
     * True when [packageId] is on the static essential set.
     *
     * NOTE: a name is a *hint* here, not a role. `com.anything.dialer` is NOT exempt by name — review
     * of #83 (F1) established that a name the child can choose must not buy an exemption. The same
     * applies to our own namespace: only [OWN_PACKAGE] is exempt, not every `com.familyshield.*` name
     * (issue #192). The system-gated segment match lives in [isEssential] with [PackageFacts].
     */
    fun isEssential(packageId: String?): Boolean {
        if (packageId.isNullOrBlank()) return false
        return packageId in EXACT
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

    /**
     * The package a block decision is about, given the accessibility event's package (a **hint**) and
     * the package of the window actually in front (**the authority**).
     *
     * Issue #165, reopened on the Flip4: the Home transition is reported under [FRAMEWORK_PACKAGE], so
     * deciding from the event package answered BLOCK for a screen that is not an app and the overlay
     * covered the launcher. The window in front is resolved first; the event package is used only when
     * the window is unknown, and it is never trusted when it is [FRAMEWORK_PACKAGE] itself.
     *
     * `null` means "no app can be named": the caller must **not** raise a block overlay for it. This is
     * the deliberately narrow trade — the framework package fronts dialogs and shell surfaces too, so
     * treating the name as an app would either exempt much more than Home (if added to the set) or
     * cover things that are not apps (if not). Nothing is blocked on the strength of `android` alone;
     * a real app's event still names that app.
     */
    fun foregroundPackage(eventPackage: String?, windowPackage: String?): String? {
        if (!windowPackage.isNullOrBlank() && windowPackage != FRAMEWORK_PACKAGE) return windowPackage
        if (!eventPackage.isNullOrBlank() && eventPackage != FRAMEWORK_PACKAGE) return eventPackage
        return null
    }
}
