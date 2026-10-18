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
        "the agent itself" to "com.familyshield.agent",
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
