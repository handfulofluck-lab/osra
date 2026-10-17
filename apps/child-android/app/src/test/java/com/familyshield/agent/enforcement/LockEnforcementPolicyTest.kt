package com.familyshield.agent.enforcement

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/** Plan 1.3: when the persisted lock must be re-raised over the foreground window. */
class LockEnforcementPolicyTest {
    private val own = "com.familyshield.agent"

    @Test
    fun `locking modes are locked, paused and paused_internet only`() {
        assertTrue(LockEnforcementPolicy.isLockingMode("locked"))
        assertTrue(LockEnforcementPolicy.isLockingMode("paused"))
        assertTrue(LockEnforcementPolicy.isLockingMode("paused_internet"))
        assertFalse(LockEnforcementPolicy.isLockingMode("none"))
        assertFalse(LockEnforcementPolicy.isLockingMode("unlock"))
        assertFalse(LockEnforcementPolicy.isLockingMode(null))
    }

    @Test
    fun `re-raises over the launcher, recents, settings and other apps while locked`() {
        for (pkg in listOf("com.sec.android.app.launcher", "com.android.settings", "com.whatsapp", "com.google.android.youtube")) {
            assertTrue(pkg, LockEnforcementPolicy.shouldReraise("locked", pkg, own))
            assertTrue(pkg, LockEnforcementPolicy.shouldReraise("paused_internet", pkg, own))
        }
    }

    @Test
    fun `never over a call, the emergency dialer, the system UI or itself, and never when not locked`() {
        for (pkg in listOf("com.samsung.android.incallui", "com.android.incallui", "com.android.emergency", "com.android.systemui", "com.google.android.dialer", own)) {
            assertFalse(pkg, LockEnforcementPolicy.shouldReraise("locked", pkg, own))
        }
        assertFalse(LockEnforcementPolicy.shouldReraise("none", "com.whatsapp", own))
        assertFalse(LockEnforcementPolicy.shouldReraise("locked", null, own))
        assertFalse(LockEnforcementPolicy.shouldReraise("locked", "", own))
    }

    /**
     * Issue #80: the exemption list was written against AOSP names, so the one device we test — a
     * Samsung Flip4 whose emergency dialer is `com.samsung.android.emergency` — had the overlay raised
     * over its own dialer while this suite was green. A missed OEM name blocks an emergency call, so the
     * table is explicit and the rule also matches the segment for names we have not seen.
     */
    @Test
    fun `every OEM emergency and dialer package stays reachable under lock`() {
        val packages = linkedMapOf(
            "Samsung Flip4 emergency dialer (the #80 case)" to "com.samsung.android.emergency",
            "AOSP emergency" to "com.android.emergency",
            "Google emergency" to "com.google.android.emergency",
            "AOSP dialer" to "com.android.dialer",
            "Google dialer" to "com.google.android.dialer",
            "Samsung dialer" to "com.samsung.android.dialer",
            "AOSP in-call UI" to "com.android.incallui",
            "Samsung in-call UI" to "com.samsung.android.incallui",
            "Google in-call UI" to "com.google.android.incallui",
            "system UI" to "com.android.systemui",
            "telephony" to "com.android.phone",
            "Samsung telephony" to "com.samsung.android.phone",
            "an OEM nobody listed yet" to "com.someoem.emergency",
            "another OEM gesture dialer" to "com.another.dialer",
        )
        for ((label, pkg) in packages) {
            assertFalse("$label ($pkg) must stay reachable", LockEnforcementPolicy.shouldReraise("locked", pkg, own))
            assertTrue("$label ($pkg) is exempt", LockEnforcementPolicy.isExemptPackage(pkg))
        }
    }

    @Test
    fun `the segment rule does not exempt ordinary apps that merely mention those words`() {
        val mustLock = listOf(
            "com.whatsapp",
            "com.instagram.android",
            "com.example.emergencygame", // a game, not a dialer: segment equality, not substring
            "com.example.dialerapp",
            "com.example.phonebook",
        )
        for (pkg in mustLock) {
            assertTrue("$pkg must be locked", LockEnforcementPolicy.shouldReraise("locked", pkg, own))
            assertFalse("$pkg is not exempt", LockEnforcementPolicy.isExemptPackage(pkg))
        }
        assertFalse("own app", LockEnforcementPolicy.shouldReraise("locked", own, own))
    }
}
