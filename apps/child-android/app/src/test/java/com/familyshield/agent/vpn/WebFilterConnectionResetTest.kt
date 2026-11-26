package com.familyshield.agent.vpn

import com.familyshield.agent.network.dto.WebFilterRuleDto
import java.io.File
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Issue #1224: when a parent saves a newly blocked domain or category, open TCP/QUIC browser tabs
 * keep streaming over already-established sockets until a network change forces them to reconnect.
 * The child agent performs a brief (~1 s) transient switch `MODE_SINKHOLE_ALL -> MODE_DNS` on the
 * running VPN tunnel without touching `LockState`, `LockPeriodTracker`, `LockActivity`, receipts,
 * or persistent `VpnState.mode`.
 *
 * Also exposes the shared `shouldResetConnections` / `runBounceIfEligible` / `resetOpenConnections`
 * seam for `#1226` (SafeSearch policy-change trigger).
 */
class WebFilterConnectionResetTest {

    /**
     * Mutant: skip the `MODE_SINKHOLE_ALL` or `MODE_DNS` hop, invert their order, or ignore `pauseMs` ->
     * `events` fails to match `["mode:sinkhole_all", "wait:1000", "mode:dns"]`.
     */
    @Test
    fun `newly blocked domain triggers exactly one sinkhole-then-DNS switch with 1s pause`() = runBlocking {
        val before = WebFilterRuleDto(blockedDomains = listOf("example.com"))
        val after = WebFilterRuleDto(blockedDomains = listOf("example.com", "  YouTube.COM. "))
        val events = mutableListOf<String>()

        val bounced = WebFilterConnectionReset.runBounceIfEligible(
            policyTriggered = WebFilterConnectionReset.shouldResetConnections(before, after),
            readState = { WebFilterConnectionReset.TunnelState() },
            switchMode = { mode -> events += "mode:$mode"; true },
            waitMs = { ms -> events += "wait:$ms" },
        )

        assertTrue("newly blocked domain must trigger bounce", bounced)
        assertEquals(
            listOf("mode:sinkhole_all", "wait:1000", "mode:dns"),
            events,
        )
    }

    /**
     * Mutant: check only `blockedDomains` and ignore `blockedCategories` -> `shouldResetConnections`
     * returns false and `events` is empty.
     */
    @Test
    fun `newly blocked category triggers one sinkhole-then-DNS switch`() = runBlocking {
        val before = WebFilterRuleDto(blockedCategories = listOf("gambling"))
        val after = WebFilterRuleDto(blockedCategories = listOf("gambling", " Adult "))
        val events = mutableListOf<String>()

        val bounced = WebFilterConnectionReset.runBounceIfEligible(
            policyTriggered = WebFilterConnectionReset.shouldResetConnections(before, after),
            readState = { WebFilterConnectionReset.TunnelState() },
            switchMode = { mode -> events += "mode:$mode"; true },
            waitMs = { ms -> events += "wait:$ms" },
        )

        assertTrue("newly blocked category must trigger bounce", bounced)
        assertEquals(listOf("mode:sinkhole_all", "wait:1000", "mode:dns"), events)
    }

    /**
     * Mutant: compare raw `blockedDomains` without subtracting `allowedDomains` -> removing an explicit
     * allow override that had exempted a blocked domain fails to reset open tabs for that domain.
     */
    @Test
    fun `removing an allowedDomains exemption that uncovers an existing blocked domain triggers bounce`() {
        val before = WebFilterRuleDto(
            blockedDomains = listOf("youtube.com"),
            allowedDomains = listOf("youtube.com"),
        )
        val after = WebFilterRuleDto(
            blockedDomains = listOf("youtube.com"),
            allowedDomains = emptyList(),
        )

        assertTrue(WebFilterConnectionReset.hasNewWebBlock(before, after))
    }

    /**
     * Mutant: trigger on any webFilter inequality (`before != after`) -> unblocking a domain/category
     * or adding an allowed domain blips active calls/tabs.
     */
    @Test
    fun `allow-only, unblock, case-only edit, or unchanged rules do not switch tunnel`() = runBlocking {
        val base = WebFilterRuleDto(
            blockedDomains = listOf("youtube.com", "tiktok.com"),
            blockedCategories = listOf("adult", "gambling"),
            allowedDomains = listOf("khanacademy.org"),
        )
        val cases = listOf(
            "unchanged" to base.copy(),
            "case and trailing dot only" to base.copy(blockedDomains = listOf("YOUTUBE.COM.", "*.tiktok.com")),
            "domain unblocked" to base.copy(blockedDomains = listOf("youtube.com")),
            "category unblocked" to base.copy(blockedCategories = listOf("adult")),
            "domain explicitly allowed" to base.copy(allowedDomains = listOf("khanacademy.org", "youtube.com")),
            "new allowed domain only" to base.copy(allowedDomains = listOf("khanacademy.org", "wikipedia.org")),
            "adding blocked domain that is already explicitly allowed" to base.copy(
                blockedDomains = listOf("youtube.com", "tiktok.com", "khanacademy.org"),
            ),
        )

        for ((label, after) in cases) {
            val events = mutableListOf<String>()
            val bounced = WebFilterConnectionReset.runBounceIfEligible(
                policyTriggered = WebFilterConnectionReset.shouldResetConnections(base, after),
                readState = { WebFilterConnectionReset.TunnelState() },
                switchMode = { mode -> events += mode; true },
                waitMs = { events += "wait" },
            )
            assertFalse("$label must not bounce", bounced)
            assertTrue("$label must emit no tunnel switches", events.isEmpty())
        }
    }

    /**
     * Mutant: omit any of the paused/locked/stopped/unconsented guards in `canStartBounce` -> at least
     * one ineligible state below switches the tunnel, reviving a stopped VPN (#848) or disturbing a
     * paused/locked device.
     */
    @Test
    fun `paused, locked, stopped, or unconsented states never switch tunnel`() = runBlocking {
        val before = WebFilterRuleDto()
        val after = WebFilterRuleDto(blockedDomains = listOf("youtube.com"))
        val ineligibleStates = listOf(
            "internetPaused" to WebFilterConnectionReset.TunnelState(internetPaused = true),
            "lockActive (locked or paused)" to WebFilterConnectionReset.TunnelState(lockActive = true),
            "tunnel in sinkhole_all" to WebFilterConnectionReset.TunnelState(tunnelMode = FilterVpnService.MODE_SINKHOLE_ALL),
            "persistent mode sinkhole_all" to WebFilterConnectionReset.TunnelState(persistentMode = FilterVpnService.MODE_SINKHOLE_ALL),
            "tunnel null (not established)" to WebFilterConnectionReset.TunnelState(tunnelMode = null),
            "service stopped" to WebFilterConnectionReset.TunnelState(serviceRunning = false),
            "vpn disabled" to WebFilterConnectionReset.TunnelState(vpnEnabled = false),
            "vpn not prepared (OS consent revoked)" to WebFilterConnectionReset.TunnelState(vpnPrepared = false),
            "family consent paused (428)" to WebFilterConnectionReset.TunnelState(consentPaused = true),
        )

        for ((label, state) in ineligibleStates) {
            val events = mutableListOf<String>()
            val bounced = WebFilterConnectionReset.runBounceIfEligible(
                policyTriggered = WebFilterConnectionReset.shouldResetConnections(before, after),
                readState = { state },
                switchMode = { mode -> events += mode; true },
                waitMs = { events += "wait" },
            )
            assertFalse("$label must not bounce", bounced)
            assertTrue("$label must not touch tunnel", events.isEmpty())
        }
    }

    /**
     * Mutant: restore `MODE_DNS` unconditionally after `waitMs` -> a `pause_internet` or VPN stop
     * arriving during the 1-second window gets overwritten back to `MODE_DNS`.
     * Conversely, a screen-only `lock` (`lockActive = true`, `internetPaused = false`) arriving mid-bounce
     * MUST still restore `MODE_DNS` so the transient sinkhole never leaks.
     */
    @Test
    fun `mid-bounce pause_internet or stop suppresses DNS restore while screen lock still restores DNS`() = runBlocking {
        // 1. pause_internet arrives during the 1s delay -> keep MODE_SINKHOLE_ALL
        var state1 = WebFilterConnectionReset.TunnelState()
        val events1 = mutableListOf<String>()
        WebFilterConnectionReset.runBounceIfEligible(
            policyTriggered = true,
            readState = { state1 },
            switchMode = { mode -> events1 += mode; true },
            waitMs = {
                state1 = state1.copy(
                    internetPaused = true,
                    persistentMode = FilterVpnService.MODE_SINKHOLE_ALL,
                    lockActive = true,
                )
            },
        )
        assertEquals("pause_internet mid-window must keep sinkhole_all", listOf("sinkhole_all"), events1)

        // 2. VPN stopped during the 1s delay -> do not revive (#848)
        var state2 = WebFilterConnectionReset.TunnelState()
        val events2 = mutableListOf<String>()
        WebFilterConnectionReset.runBounceIfEligible(
            policyTriggered = true,
            readState = { state2 },
            switchMode = { mode -> events2 += mode; true },
            waitMs = { state2 = state2.copy(serviceRunning = false, tunnelMode = null) },
        )
        assertEquals("stopped VPN mid-window must not be revived", listOf("sinkhole_all"), events2)

        // 3. Screen-only lock arrives during the 1s delay -> still restores MODE_DNS
        var state3 = WebFilterConnectionReset.TunnelState()
        val events3 = mutableListOf<String>()
        WebFilterConnectionReset.runBounceIfEligible(
            policyTriggered = true,
            readState = { state3 },
            switchMode = { mode -> events3 += mode; true },
            waitMs = { state3 = state3.copy(lockActive = true) },
        )
        assertEquals("screen-only lock mid-window must still restore dns", listOf("sinkhole_all", "dns"), events3)
    }

    /**
     * Source-wiring guard (#1224):
     * - Mutant 1: read `beforeWebFilter` after `rules.refresh()` -> `before == after`, never bounces.
     * - Mutant 2: touch `LockState.set`, `LockPeriodTracker`, or `LockActivity` in `rules_updated` or
     *   `WebFilterConnectionReset` -> flashes paused UI / writes fake pause history.
     * - Mutant 3: persist `MODE_SINKHOLE_ALL` via `VpnState.setMode` inside `applyTransientMode`, or skip
     *   persisting `VpnState.setMode(this, wanted)` on normal `onStartCommand` when `mode == wanted` ->
     *   either strands the phone in sinkhole mode across a crash or drops persistent `pause_internet`.
     */
    @Test
    fun `rules_updated and FilterVpnService wire transient reset without LockState or persistent mode drift`() {
        val dispatcher = sourceFile("app/src/main/java/com/familyshield/agent/commands/CommandDispatcher.kt")
        val rulesBranch = dispatcher.substringAfter("\"rules_updated\" ->").substringBefore("\"locate_now\" ->")
        val beforeIdx = rulesBranch.indexOf("val beforeWebFilter")
        val refreshIdx = rulesBranch.indexOf("rules.refresh()")
        val resetIdx = rulesBranch.indexOf("WebFilterConnectionReset.resetIfNeeded(")

        assertTrue("beforeWebFilter must be captured before rules.refresh()", beforeIdx in 0..<refreshIdx)
        assertTrue("resetIfNeeded must run after refreshThenReload", resetIdx > refreshIdx)
        assertFalse("rules_updated must not set LockState", rulesBranch.contains("LockState.set"))
        assertFalse("rules_updated must not record a LockPeriod", rulesBranch.contains("LockPeriodTracker"))
        assertFalse("rules_updated must not launch LockActivity", rulesBranch.contains("LockActivity"))

        val helperCode = stripComments(sourceFile("app/src/main/java/com/familyshield/agent/vpn/WebFilterConnectionReset.kt"))
        assertFalse("helper must not set LockState", helperCode.contains("LockState.set"))
        assertFalse("helper must not touch LockPeriodTracker", helperCode.contains("LockPeriodTracker"))
        assertFalse("helper must not launch LockActivity", helperCode.contains("LockActivity"))

        val vpn = sourceFile("app/src/main/java/com/familyshield/agent/vpn/FilterVpnService.kt")
        val onStart = vpn.substringAfter("override fun onStartCommand(").substringBefore("override fun onRevoke()")
        val transientFn = vpn.substringAfter("private fun applyTransientMode(").substringBefore("private fun pumpLoop(")
        assertTrue("onStartCommand must dispatch ACTION_TRANSIENT_MODE", onStart.contains("ACTION_TRANSIENT_MODE"))
        assertTrue(
            "normal start must always persist VpnState.setMode(this, wanted) even during a transient sinkhole",
            onStart.contains("VpnState.setMode(this, wanted)"),
        )
        assertFalse(
            "applyTransientMode must never overwrite persistent VpnState.setMode",
            transientFn.contains("VpnState.setMode("),
        )
    }

    private fun stripComments(src: String): String =
        src.replace(Regex("/\\*[\\s\\S]*?\\*/"), "").replace(Regex("//.*"), "")

    private fun sourceFile(relative: String): String {
        var dir: File? = File(System.getProperty("user.dir") ?: ".").absoluteFile
        while (dir != null) {
            val candidate = File(dir, relative)
            if (candidate.isFile) return candidate.readText()
            dir = dir.parentFile
        }
        throw AssertionError("could not find $relative from ${System.getProperty("user.dir")}")
    }
}