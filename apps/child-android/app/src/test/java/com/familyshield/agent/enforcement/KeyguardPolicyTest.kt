package com.familyshield.agent.enforcement

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Issue #87: with a secure keyguard up, the overlay must step back so the owner can enter their PIN.
 * Written as a table because the failure on 2026-10-17 was not a wrong branch — it was no branch at all.
 */
class KeyguardPolicyTest {

    @Test
    fun `every locking mode defers while the keyguard is up`() {
        for (mode in listOf("locked", "paused", "paused_internet", "blocked", null, "")) {
            assertTrue("$mode must defer", KeyguardPolicy.shouldDeferToKeyguard(mode, keyguardLocked = true))
        }
    }

    @Test
    fun `the two modes that end a lock must still run while the keyguard is up`() {
        assertFalse(KeyguardPolicy.shouldDeferToKeyguard("unlock", keyguardLocked = true))
        assertFalse(KeyguardPolicy.shouldDeferToKeyguard("dismiss", keyguardLocked = true))
    }

    @Test
    fun `nothing defers when the keyguard is down`() {
        for (mode in listOf("locked", "paused", "paused_internet", "unlock", "dismiss")) {
            assertFalse(mode, KeyguardPolicy.shouldDeferToKeyguard(mode, keyguardLocked = false))
        }
    }

    /**
     * The policy carries its own copy of the two mode names so it stays pure. This pins the coupling:
     * if `LockActivity` ever renames a constant, the test fails instead of the rule silently inverting.
     */
    @Test
    fun `the policy's mode names match the activity's constants`() {
        assertFalse(KeyguardPolicy.shouldDeferToKeyguard(com.familyshield.agent.commands.LockActivity.MODE_UNLOCK, keyguardLocked = true))
        assertFalse(KeyguardPolicy.shouldDeferToKeyguard(com.familyshield.agent.commands.LockActivity.MODE_DISMISS, keyguardLocked = true))
        assertTrue(KeyguardPolicy.shouldDeferToKeyguard(com.familyshield.agent.commands.LockActivity.MODE_LOCKED, keyguardLocked = true))
    }
}
