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
}
