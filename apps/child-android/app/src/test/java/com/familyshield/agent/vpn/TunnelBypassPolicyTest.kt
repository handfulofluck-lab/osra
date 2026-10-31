package com.familyshield.agent.vpn

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Issue #458: during a `sinkhole_all` pause the tunnel drops every packet, so once FCM's socket drops
 * it cannot reconnect and a `resume_internet` waits for the next poll — up to 15 minutes. The fix is to
 * keep the wake path outside the tunnel in pause mode, and to keep that decision in one pure place.
 *
 * Mutant for the first row: delete the `if (sinkholeAll) packages += FCM_PACKAGE` line and it goes red
 * (the list becomes self + always-allowed only).
 */
class TunnelBypassPolicyTest {

    @Test
    fun `pause mode keeps the FCM wake path outside the tunnel`() {
        val excluded = TunnelBypassPolicy.excludedPackages(
            sinkholeAll = true,
            selfPackage = "com.osratech.child",
            alwaysAllowedApps = emptyList(),
        )
        assertEquals(listOf("com.osratech.child", "com.google.android.gms"), excluded)
    }

    @Test
    fun `the DNS-only tunnel excludes nothing but the agent itself`() {
        // The DNS tunnel routes one address; a wider exclusion list would be surface with no reason.
        val excluded = TunnelBypassPolicy.excludedPackages(
            sinkholeAll = false,
            selfPackage = "com.osratech.child",
            alwaysAllowedApps = listOf("com.example.dialer"),
        )
        assertEquals(listOf("com.osratech.child", "com.example.dialer"), excluded)
        assertFalse("gms must not be excluded outside a pause", "com.google.android.gms" in excluded)
    }

    @Test
    fun `the agent itself is always first, because its own poll must never land in its own sinkhole`() {
        val excluded = TunnelBypassPolicy.excludedPackages(
            sinkholeAll = true,
            selfPackage = "com.osratech.child",
            alwaysAllowedApps = listOf("com.example.dialer"),
        )
        assertEquals("com.osratech.child", excluded.first())
        assertTrue("com.example.dialer" in excluded)
    }

    @Test
    fun `an always-allowed gms is not added twice`() {
        val excluded = TunnelBypassPolicy.excludedPackages(
            sinkholeAll = true,
            selfPackage = "com.osratech.child",
            alwaysAllowedApps = listOf(TunnelBypassPolicy.FCM_PACKAGE),
        )
        assertEquals(1, excluded.count { it == TunnelBypassPolicy.FCM_PACKAGE })
    }

    @Test
    fun `blank names never reach the builder`() {
        // VpnService.Builder throws on an empty package name, and a thrown exclusion reads in a log as
        // if it had been applied.
        val excluded = TunnelBypassPolicy.excludedPackages(
            sinkholeAll = true,
            selfPackage = "com.osratech.child",
            alwaysAllowedApps = listOf("", "  ", "com.example.dialer"),
        )
        assertEquals(listOf("com.osratech.child", "com.google.android.gms", "com.example.dialer"), excluded)
    }

    @Test
    fun `the Play Store is not excluded, so it stays inside the pause`() {
        // The trade in the issue: Play services wakes the phone, the store is still content.
        val excluded = TunnelBypassPolicy.excludedPackages(
            sinkholeAll = true,
            selfPackage = "com.osratech.child",
            alwaysAllowedApps = emptyList(),
        )
        assertFalse("com.android.vending" in excluded)
    }
}
