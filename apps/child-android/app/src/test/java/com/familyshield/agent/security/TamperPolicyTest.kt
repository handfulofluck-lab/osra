package com.familyshield.agent.security

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/** ADR-0010: the tier table and the removal rule. */
class TamperPolicyTest {

    @Test
    fun `tier follows what the OS granted, owner implies admin`() {
        assertEquals(ProtectionTier.NONE, TamperPolicy.tierOf(isAdminActive = false, isDeviceOwner = false))
        assertEquals(ProtectionTier.ADMIN, TamperPolicy.tierOf(isAdminActive = true, isDeviceOwner = false))
        assertEquals(ProtectionTier.OWNER, TamperPolicy.tierOf(isAdminActive = true, isDeviceOwner = true))
        assertEquals(ProtectionTier.OWNER, TamperPolicy.tierOf(isAdminActive = false, isDeviceOwner = true))
    }

    @Test
    fun `once a pin exists every removal action needs it`() {
        for (action in ProtectedAction.values()) {
            assertTrue(TamperPolicy.removalAllowed(action, pinConfigured = false, pinVerified = false))
            assertFalse(TamperPolicy.removalAllowed(action, pinConfigured = true, pinVerified = false))
            assertTrue(TamperPolicy.removalAllowed(action, pinConfigured = true, pinVerified = true))
        }
    }

    @Test
    fun `a drop to NONE alerts exactly once, other transitions do not`() {
        assertTrue(TamperPolicy.shouldAlertOnTier(ProtectionTier.ADMIN, ProtectionTier.NONE))
        assertTrue(TamperPolicy.shouldAlertOnTier(ProtectionTier.OWNER, ProtectionTier.NONE))
        assertFalse(TamperPolicy.shouldAlertOnTier(ProtectionTier.NONE, ProtectionTier.NONE))
        assertFalse(TamperPolicy.shouldAlertOnTier(ProtectionTier.NONE, ProtectionTier.ADMIN))
        assertFalse(TamperPolicy.shouldAlertOnTier(ProtectionTier.ADMIN, ProtectionTier.OWNER))
    }

    @Test
    fun `only the owner tier has an OS-level uninstall block`() {
        assertTrue(TamperPolicy.uninstallBlockedByOs(ProtectionTier.OWNER))
        assertFalse(TamperPolicy.uninstallBlockedByOs(ProtectionTier.ADMIN))
        assertFalse(TamperPolicy.uninstallBlockedByOs(ProtectionTier.NONE))
    }
}
