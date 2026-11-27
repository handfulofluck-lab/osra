package com.familyshield.agent.vpn

import java.io.File
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Beta-A blocker #934: after an app update (`adb install -r` or Play Store update), Android kills
 * the previous process without running `FilterVpnService.onDestroy`, leaving `osra_vpn_state.xml`
 * with `established=true` while no VPN tunnel exists.
 *
 * Mutants pinned by these rows (AGENTS.md §3):
 * - Mutant 1: remove `liveTunnelMode != null` from [FilterRecoveryPolicy.isTunnelEstablished] ->
 *   `stale persisted flag alone never claims the tunnel is established` fails.
 * - Mutant 2: remove `!consentPaused` from [FilterRecoveryPolicy.shouldRestartAfterUpdate] ->
 *   `update recovery respects withdrawn consent, pairing, vpn readiness, and already-live tunnel` fails.
 * - Mutant 3: remove `!filterLost` from [FilterRecoveryPolicy.shouldRestartAfterUpdate] ->
 *   `update recovery refuses to resurrect an explicitly revoked filter` fails (and only that row).
 * - Mutant 4: remove `FilterVpnService.start` from `PackageReplacedReceiver.kt` ->
 *   `PackageReplacedReceiver clears stale state, reschedules work, and restarts web filter after genuine self-replace` fails.
 * - Mutant 5: omit the `shouldAutoReconnectOnStatusOpen` guard from the `c01ChildHomeEnabled` branch in
 *   `PairingActivity.showStatus` -> `PairingActivity C-01 Child Home path also auto-reconnects via FilterRecoveryPolicy when tunnel is down` fails.
 */
class FilterRecoveryPolicyTest {

    @Test
    fun `stale persisted flag alone never claims the tunnel is established`() {
        assertFalse(FilterRecoveryPolicy.isTunnelEstablished(persistedEstablished = true, liveTunnelMode = null))
        assertFalse(FilterRecoveryPolicy.isTunnelEstablished(persistedEstablished = false, liveTunnelMode = "dns"))
        assertFalse(FilterRecoveryPolicy.isTunnelEstablished(persistedEstablished = false, liveTunnelMode = null))
        assertTrue(FilterRecoveryPolicy.isTunnelEstablished(persistedEstablished = true, liveTunnelMode = "dns"))
        assertTrue(FilterRecoveryPolicy.isTunnelEstablished(persistedEstablished = true, liveTunnelMode = "sinkhole_all"))
    }

    @Test
    fun `update recovery restarts web filter when paired, enabled, prepared, consented, not revoked, and tunnel is down`() {
        assertTrue(
            FilterRecoveryPolicy.shouldRestartAfterUpdate(
                isPaired = true,
                vpnEnabled = true,
                vpnPrepared = true,
                consentPaused = false,
                filterLost = false,
                liveTunnelMode = null,
            ),
        )
    }

    @Test
    fun `update recovery respects withdrawn consent, pairing, vpn readiness, and already-live tunnel`() {
        assertFalse(
            FilterRecoveryPolicy.shouldRestartAfterUpdate(
                isPaired = false, vpnEnabled = true, vpnPrepared = true, consentPaused = false, filterLost = false, liveTunnelMode = null,
            ),
        )
        assertFalse(
            FilterRecoveryPolicy.shouldRestartAfterUpdate(
                isPaired = true, vpnEnabled = false, vpnPrepared = true, consentPaused = false, filterLost = false, liveTunnelMode = null,
            ),
        )
        assertFalse(
            FilterRecoveryPolicy.shouldRestartAfterUpdate(
                isPaired = true, vpnEnabled = true, vpnPrepared = false, consentPaused = false, filterLost = false, liveTunnelMode = null,
            ),
        )
        assertFalse(
            FilterRecoveryPolicy.shouldRestartAfterUpdate(
                isPaired = true, vpnEnabled = true, vpnPrepared = true, consentPaused = true, filterLost = false, liveTunnelMode = null,
            ),
        )
        assertFalse(
            FilterRecoveryPolicy.shouldRestartAfterUpdate(
                isPaired = true, vpnEnabled = true, vpnPrepared = true, consentPaused = false, filterLost = false, liveTunnelMode = "dns",
            ),
        )
    }

    @Test
    fun `update recovery refuses to resurrect an explicitly revoked filter`() {
        assertFalse(
            FilterRecoveryPolicy.shouldRestartAfterUpdate(
                isPaired = true,
                vpnEnabled = true,
                vpnPrepared = true,
                consentPaused = false,
                filterLost = true,
                liveTunnelMode = null,
            ),
        )
    }

    @Test
    fun `status screen auto-reconnect runs only when enabled, prepared, consented, not revoked, and tunnel is down`() {
        assertTrue(
            FilterRecoveryPolicy.shouldAutoReconnectOnStatusOpen(
                vpnEnabled = true, vpnPrepared = true, consentPaused = false, filterLost = false, liveTunnelMode = null,
            ),
        )
        assertFalse(
            FilterRecoveryPolicy.shouldAutoReconnectOnStatusOpen(
                vpnEnabled = true, vpnPrepared = true, consentPaused = true, filterLost = false, liveTunnelMode = null,
            ),
        )
        assertFalse(
            FilterRecoveryPolicy.shouldAutoReconnectOnStatusOpen(
                vpnEnabled = true, vpnPrepared = true, consentPaused = false, filterLost = true, liveTunnelMode = null,
            ),
        )
        assertFalse(
            FilterRecoveryPolicy.shouldAutoReconnectOnStatusOpen(
                vpnEnabled = true, vpnPrepared = true, consentPaused = false, filterLost = false, liveTunnelMode = "dns",
            ),
        )
    }

    @Test
    fun `VpnState isEstablished requires live tunnelMode via FilterRecoveryPolicy`() {
        val vpnState = sourceFile("app/src/main/java/com/familyshield/agent/vpn/VpnState.kt")
        val body = vpnState.substringAfter("fun isEstablished(").substringBefore("fun setEstablished(")
        assertTrue("delegates to FilterRecoveryPolicy.isTunnelEstablished", body.contains("FilterRecoveryPolicy.isTunnelEstablished"))
        assertTrue("checks live FilterVpnService.tunnelMode", body.contains("FilterVpnService.tunnelMode"))
    }

    @Test
    fun `FilterVpnService sets tunnelMode before persisting established`() {
        val svc = sourceFile("app/src/main/java/com/familyshield/agent/vpn/FilterVpnService.kt")
        val block = svc.substringAfter("tun = fd").substringBefore("val gen = generation.incrementAndGet()")
        val modeIdx = block.indexOf("tunnelMode = mode")
        val estIdx = block.indexOf("VpnState.setEstablished(this, true)")
        assertTrue("tunnelMode must be set before VpnState.setEstablished(this, true)", modeIdx in 0 until estIdx)
    }

    @Test
    fun `PackageReplacedReceiver clears stale state, reschedules work, and restarts web filter after genuine self-replace`() {
        val receiver = sourceFile("app/src/main/java/com/familyshield/agent/receivers/PackageReplacedReceiver.kt")
        val gateIdx = receiver.indexOf("BroadcastGate.genuineSelfReplace")
        val clearIdx = receiver.indexOf("VpnState.setEstablished(context, false)")
        val workIdx = receiver.indexOf("WorkScheduler.scheduleAll(context)")
        val policyIdx = receiver.indexOf("FilterRecoveryPolicy.shouldRestartAfterUpdate")
        val startIdx = receiver.indexOf("FilterVpnService.start(context)")
        assertTrue("genuineSelfReplace gate runs before recovery", gateIdx in 0 until clearIdx)
        assertTrue("stale established latch cleared", clearIdx > 0)
        assertTrue("periodic workers rescheduled", workIdx > gateIdx)
        assertTrue("recovery checks FilterRecoveryPolicy.shouldRestartAfterUpdate", policyIdx > gateIdx)
        assertTrue("passes live settings.isPaired() into policy", receiver.contains("isPaired = settings.isPaired()"))
        assertTrue("passes VpnState.isFilterLost into policy", receiver.contains("VpnState.isFilterLost(context, settings, consent)"))
        assertTrue("starts FilterVpnService when policy allows", startIdx > policyIdx)
    }

    @Test
    fun `PairingActivity status row auto-reconnects via FilterRecoveryPolicy when tunnel is down`() {
        val act = sourceFile("app/src/main/java/com/familyshield/agent/setup/PairingActivity.kt")
        val row = act.substringAfter("private fun addWebFilterRow(").substringBefore("private fun showStatus(")
        assertTrue("uses FilterRecoveryPolicy.shouldAutoReconnectOnStatusOpen", row.contains("FilterRecoveryPolicy.shouldAutoReconnectOnStatusOpen"))
        assertTrue("guards against reconnect loop", row.contains("vpnAutoReconnectAttempted"))
    }

    @Test
    fun `PairingActivity C-01 Child Home path also auto-reconnects via FilterRecoveryPolicy when tunnel is down`() {
        val act = sourceFile("app/src/main/java/com/familyshield/agent/setup/PairingActivity.kt")
        val c01Branch = act
            .substringAfter("if (!forceLegacy && com.familyshield.agent.ui.theme.ChildUxFlags.c01ChildHomeEnabled)")
            .substringBefore("val initialCopy = buildChildHomeCopy()")
        assertTrue("C-01 branch consults FilterRecoveryPolicy.shouldAutoReconnectOnStatusOpen", c01Branch.contains("FilterRecoveryPolicy.shouldAutoReconnectOnStatusOpen"))
        assertTrue("C-01 branch guards against reconnect loop", c01Branch.contains("vpnAutoReconnectAttempted"))
        assertTrue("C-01 branch starts FilterVpnService", c01Branch.contains("FilterVpnService.start("))
    }

    private fun sourceFile(relative: String): String {
        var dir: File? = File(System.getProperty("user.dir")).absoluteFile
        while (dir != null) {
            val candidate = File(dir, relative)
            if (candidate.isFile) return candidate.readText()
            dir = dir.parentFile
        }
        error("source file not found: $relative")
    }
}
