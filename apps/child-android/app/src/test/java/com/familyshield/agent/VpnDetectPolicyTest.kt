package com.familyshield.agent

import com.familyshield.agent.receivers.VpnDetectPolicy
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/** Pure-JVM tests for Feature #20: transport-set → VPN-routed decision. */
class VpnDetectPolicyTest {

    @Test
    fun `vpn constant mirrors the framework value`() {
        // Keeps the pure path honest if the mirrored constant ever drifts from the framework.
        assertEquals(4, VpnDetectPolicy.TRANSPORT_VPN)
    }

    @Test
    fun `null transports is not vpn`() {
        assertFalse(VpnDetectPolicy.hasVpnTransport(null as IntArray?))
    }

    @Test
    fun `empty transports is not vpn`() {
        assertFalse(VpnDetectPolicy.hasVpnTransport(intArrayOf()))
    }

    @Test
    fun `wifi plus cellular is not vpn`() {
        assertFalse(VpnDetectPolicy.hasVpnTransport(intArrayOf(1, 0)))
    }

    @Test
    fun `vpn-only transport is vpn`() {
        assertTrue(VpnDetectPolicy.hasVpnTransport(intArrayOf(VpnDetectPolicy.TRANSPORT_VPN)))
    }

    @Test
    fun `wifi plus vpn is vpn`() {
        assertTrue(VpnDetectPolicy.hasVpnTransport(intArrayOf(1, VpnDetectPolicy.TRANSPORT_VPN)))
    }
}
