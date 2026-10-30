package com.familyshield.agent.enforcement

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Issue #165: the packages the block overlay must never cover. One set serves the fail-closed path,
 * the rules path and [AppBlocker]; this pins its contents and, just as importantly, that it does not
 * leak into the lock (`LockEnforcementPolicy` deliberately covers the launcher and Settings).
 */
class EssentialPackagesTest {

    private class FakeFacts(
        private val system: Set<String> = emptySet(),
        private val roles: Set<String> = emptySet(),
        private val homes: Set<String> = emptySet(),
    ) : PackageFacts {
        override fun isSystemApp(pkg: String): Boolean = pkg in system
        override fun dialerRoleHolders(): Set<String> = roles
        override fun homePackages(): Set<String> = homes
    }

    /** The screens a child needs while a rule is blocking everything else. */
    private val mustStayReachable = linkedMapOf(
        "the Flip4 launcher (issue #165)" to "com.sec.android.app.launcher",
        "AOSP launcher" to "com.android.launcher3",
        "Pixel launcher" to "com.google.android.apps.nexuslauncher",
        "system UI" to "com.android.systemui",
        "Samsung dialer" to "com.samsung.android.dialer",
        "Google dialer" to "com.google.android.dialer",
        "AOSP dialer" to "com.android.dialer",
        "Samsung emergency dialer (the #80 case)" to "com.samsung.android.emergency",
        "AOSP emergency" to "com.android.emergency",
        "Samsung in-call UI" to "com.samsung.android.incallui",
        "telephony" to "com.android.phone",
        "the agent itself" to EssentialPackages.OWN_PACKAGE,
    )

    @Test
    fun `the launcher the system UI and the call surfaces are essential without asking the OS`() {
        for ((label, pkg) in mustStayReachable) {
            assertTrue("$label ($pkg) must never be covered", EssentialPackages.isEssential(pkg))
        }
    }

    @Test
    fun `an ordinary app is never essential, whatever it is called`() {
        // Review of #83 F1: a name the child can choose must not buy an exemption. The old fail-closed
        // list matched `*.dialer`/`*.telecom` by suffix, so a sideloaded game escaped the rule.
        val mustBlock = listOf(
            "com.game",
            "com.instagram.android",
            "com.zhiliaoapp.musically",
            "com.google.android.youtube",
            "com.evil.dialer",
            "com.example.telecom",
            "com.example.emergencygame",
            "com.android.phonebook.game",
        )
        for (pkg in mustBlock) {
            assertFalse("$pkg must stay blockable", EssentialPackages.isEssential(pkg))
            assertFalse("$pkg must stay blockable", EssentialPackages.isEssential(pkg, FakeFacts()))
        }
        assertFalse(EssentialPackages.isEssential(null))
        assertFalse(EssentialPackages.isEssential(""))
    }

    @Test
    fun `only the agent's own package is exempt from our namespace`() {
        // Issue #192: package names are global only by convention, and the Full build is sideloaded.
        // The old `startsWith("com.familyshield.")` test exempted every sibling name from every rule,
        // including the prefix-equal string itself.
        assertTrue(
            "the agent's own package must stay exempt",
            EssentialPackages.isEssential(EssentialPackages.OWN_PACKAGE),
        )
        assertTrue(
            "the overlay's PackageFacts path must exempt the agent too",
            EssentialPackages.isEssential(EssentialPackages.OWN_PACKAGE, FakeFacts()),
        )
        val impostors = listOf(
            "com.familyshield.notanapp",
            "com.familyshield.agent.notanapp",
            "com.familyshield.agent.test",
            "com.familyshield.",
            "com.familyshield",
            "com.familyshieldx",
        )
        for (pkg in impostors) {
            assertFalse("$pkg must stay blockable", EssentialPackages.isEssential(pkg))
            assertFalse(
                "$pkg must stay blockable through PackageFacts",
                EssentialPackages.isEssential(pkg, FakeFacts()),
            )
        }
    }

    // 2026-10-29 (Karim's decision 2B): the Play identity moved from `com.familyshield.agent` to
    // `com.osratech.child`, and `OWN_PACKAGE` used to be a second copy of that literal — so the
    // security list and the build file could disagree, and the agent would stop treating its own
    // overlay as essential.
    //
    // The obvious row (`OWN_PACKAGE == BuildConfig.APPLICATION_ID`) is now **true by construction**
    // and could not fail, so it is not written. This one can: it reads the source and rejects a
    // literal, which is the only shape that lets the two drift apart again.
    // Mutant: change `val OWN_PACKAGE: String = BuildConfig.APPLICATION_ID` back to
    // `const val OWN_PACKAGE: String = "com.familyshield.agent"` — this row goes red.
    @Test
    fun `OWN_PACKAGE is derived from the build, never a second copy of the id`() {
        val source = java.io.File(
            "src/main/java/com/familyshield/agent/enforcement/EssentialPackages.kt",
        )
        assertTrue(
            "JVM unit tests run from the module directory; if this file is missing the row would " +
                "pass vacuously, so its absence is a failure",
            source.isFile,
        )
        val declaration = source.readLines()
            .firstOrNull { it.contains("val OWN_PACKAGE") }
        assertTrue("OWN_PACKAGE must still be declared in one piece", declaration != null)
        assertTrue(
            "OWN_PACKAGE must come from BuildConfig.APPLICATION_ID, not from a string literal: " +
                "found `${declaration?.trim()}`",
            declaration!!.contains("BuildConfig.APPLICATION_ID"),
        )
        assertFalse(
            "a quoted package name here is the drift this row exists to stop",
            declaration.contains("\""),
        )
    }

    @Test
    fun `whatever currently holds HOME is the launcher, even a name no table knows`() {
        val facts = FakeFacts(homes = setOf("com.oneplus.launcher"))
        assertTrue(EssentialPackages.isEssential("com.oneplus.launcher", facts))
        assertFalse("an app that is not the HOME handler stays blockable", EssentialPackages.isEssential("com.oneplus.launcher"))
        assertFalse(EssentialPackages.isEssential("com.oneplus.notes", facts))
    }

    @Test
    fun `the OS dialer role and a system dialer name stay reachable, a sideloaded one does not`() {
        val facts = FakeFacts(system = setOf("com.oneplus.dialer"), roles = setOf("com.oneplus.telephony"))
        assertTrue("a system dialer outside the table", EssentialPackages.isEssential("com.oneplus.dialer", facts))
        assertTrue("the OS-assigned dialer role", EssentialPackages.isEssential("com.oneplus.telephony", facts))
        assertFalse("a sideloaded dialer name", EssentialPackages.isEssential("com.evil.dialer", facts))
    }

    @Test
    fun `the essential set does not change what the lock covers`() {
        val facts = FakeFacts(system = setOf("com.sec.android.app.launcher", "com.samsung.android.dialer"))
        assertTrue(EssentialPackages.isEssential("com.sec.android.app.launcher", facts))
        // Plan 1.3/ADR-0010: a parent's lock must still come back over the home screen...
        assertTrue(LockEnforcementPolicy.shouldReraise("locked", "com.sec.android.app.launcher", "com.familyshield.agent", facts))
        assertTrue(LockEnforcementPolicy.shouldReraise("locked", "com.android.settings", "com.familyshield.agent", facts))
        // ...but never over a call.
        assertFalse(LockEnforcementPolicy.shouldReraise("locked", "com.samsung.android.dialer", "com.familyshield.agent", facts))
    }
}
