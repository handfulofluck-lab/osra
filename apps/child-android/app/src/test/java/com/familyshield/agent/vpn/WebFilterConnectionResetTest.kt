package com.familyshield.agent.vpn

import com.familyshield.agent.network.dto.WebFilterRuleDto
import java.io.File
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.async
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.yield
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Issue #1224 (and reliability hardening): service-owned transient `MODE_SINKHOLE_ALL -> MODE_DNS`
 * connection reset when a domain or category is newly blocked, plus shared policy seam for `#1226`.
 */
class WebFilterConnectionResetTest {

    /**
     * Synthetic harness mirroring `FilterVpnService`'s authoritative vs active tunnel state:
     * `openTunnel` closes any existing fd (`activeMode = null`) BEFORE attempting `establish(wanted)`,
     * so failed entry or failed restore leaves `activeMode == null` (or transient sinkhole) unless
     * explicitly recovered or closed by `TransientTunnelController`.
     */
    private class SyntheticServiceHarness(
        var authorizedMode: String = FilterVpnService.MODE_DNS,
        var activeMode: String? = FilterVpnService.MODE_DNS,
        var internetPaused: Boolean = false,
        var consentPaused: Boolean = false,
        var lockActive: Boolean = false,
        var stopping: Boolean = false,
        val onEstablish: suspend SyntheticServiceHarness.(String, Int) -> Boolean = { _, _ -> true },
        val onWait: suspend SyntheticServiceHarness.(Long) -> Unit = { ms -> nowMs += ms },
    ) {
        var nowMs: Long = 0L
        val log = mutableListOf<String>()
        private val attemptCounts = mutableMapOf<String, Int>()

        val controller: WebFilterConnectionReset.TransientTunnelController

        init {
            controller = WebFilterConnectionReset.TransientTunnelController(
                readSnapshot = {
                    WebFilterConnectionReset.ServiceSnapshot(
                        authorizedMode = authorizedMode,
                        activeMode = activeMode,
                        internetPaused = internetPaused,
                        consentPaused = consentPaused,
                        lockActive = lockActive,
                        stopping = stopping,
                    )
                },
                openMode = { wanted ->
                    // Mirrors FilterVpnService.openTunnel(): stopTunnel() closes the previous fd first.
                    activeMode = null
                    val n = (attemptCounts[wanted] ?: 0) + 1
                    attemptCounts[wanted] = n
                    log += "open:$wanted#$n@${nowMs}"
                    val ok = onEstablish(wanted, n)
                    if (ok) {
                        activeMode = wanted
                        log += "active:$wanted@${nowMs}"
                    } else {
                        log += "fail:$wanted#$n@${nowMs}"
                    }
                    ok
                },
                closeTunnel = {
                    activeMode = null
                    log += "close@${nowMs}"
                },
                waitMs = { ms ->
                    log += "wait:${ms}@${nowMs}"
                    onWait(ms)
                },
            )
        }
    }

    /**
     * Mutant: skip `MODE_SINKHOLE_ALL` or `MODE_DNS`, invert order, or skip `1000 ms` hold ->
     * `log` fails to record `sinkhole_all -> wait:1000 -> dns` or outcome is not `COMPLETED`.
     */
    @Test
    fun `newly blocked domain triggers one service-owned sinkhole-then-DNS transition`() = runBlocking {
        val before = WebFilterRuleDto(blockedDomains = listOf("example.com"))
        val after = WebFilterRuleDto(blockedDomains = listOf("example.com", "  YouTube.COM. "))
        assertTrue(WebFilterConnectionReset.shouldResetConnections(before, after))

        val harness = SyntheticServiceHarness()
        val outcome = harness.controller.executeReset()

        assertEquals(WebFilterConnectionReset.TransitionOutcome.COMPLETED, outcome)
        assertTrue(outcome.acknowledged)
        assertEquals(FilterVpnService.MODE_DNS, harness.activeMode)
        assertEquals(
            listOf("open:sinkhole_all#1@0", "active:sinkhole_all@0", "wait:1000@0", "open:dns#1@1000", "active:dns@1000"),
            harness.log,
        )
    }

    /**
     * Mutant: check only `blockedDomains` and ignore `blockedCategories` -> returns false.
     */
    @Test
    fun `newly blocked category and removed allowedDomains exemption trigger reset predicate`() {
        assertTrue(
            WebFilterConnectionReset.shouldResetConnections(
                WebFilterRuleDto(blockedCategories = listOf("gambling")),
                WebFilterRuleDto(blockedCategories = listOf("gambling", " Adult ")),
            ),
        )
        assertTrue(
            WebFilterConnectionReset.hasNewWebBlock(
                WebFilterRuleDto(blockedDomains = listOf("youtube.com"), allowedDomains = listOf("youtube.com")),
                WebFilterRuleDto(blockedDomains = listOf("youtube.com"), allowedDomains = emptyList()),
            ),
        )
    }

    /**
     * Mutant: trigger on `before != after` -> unblocking or allow-only edits return true.
     */
    @Test
    fun `allow-only, unblock, case-only edit, or unchanged rules do not trigger reset`() {
        val base = WebFilterRuleDto(
            blockedDomains = listOf("youtube.com", "tiktok.com"),
            blockedCategories = listOf("adult", "gambling"),
            allowedDomains = listOf("khanacademy.org"),
        )
        assertFalse(WebFilterConnectionReset.shouldResetConnections(base, base.copy()))
        assertFalse(WebFilterConnectionReset.shouldResetConnections(base, base.copy(blockedDomains = listOf("YOUTUBE.COM.", "*.tiktok.com"))))
        assertFalse(WebFilterConnectionReset.shouldResetConnections(base, base.copy(blockedDomains = listOf("youtube.com"))))
        assertFalse(WebFilterConnectionReset.shouldResetConnections(base, base.copy(blockedCategories = listOf("adult"))))
        assertFalse(WebFilterConnectionReset.shouldResetConnections(base, base.copy(allowedDomains = listOf("khanacademy.org", "youtube.com"))))
        assertFalse(WebFilterConnectionReset.shouldResetConnections(base, base.copy(allowedDomains = listOf("khanacademy.org", "wikipedia.org"))))
    }

    /**
     * Mutant: omit any pre-entry guard -> paused, locked, stopped, or unconsented tunnel transitions anyway.
     */
    @Test
    fun `paused, locked, stopped, or unconsented states skip transition without touching tunnel`() = runBlocking {
        val states = listOf(
            SyntheticServiceHarness(internetPaused = true),
            SyntheticServiceHarness(lockActive = true),
            SyntheticServiceHarness(authorizedMode = FilterVpnService.MODE_SINKHOLE_ALL),
            SyntheticServiceHarness(activeMode = FilterVpnService.MODE_SINKHOLE_ALL),
            SyntheticServiceHarness(activeMode = null),
            SyntheticServiceHarness(consentPaused = true),
            SyntheticServiceHarness(stopping = true),
        )
        for (h in states) {
            val outcome = h.controller.executeReset()
            assertEquals(WebFilterConnectionReset.TransitionOutcome.SKIPPED, outcome)
            assertFalse(outcome.acknowledged)
            assertTrue("ineligible state must not touch tunnel: ${h.log}", h.log.isEmpty())
        }
    }

    /**
     * Synthetic service test 1 — Failed entry:
     * `openTunnel(MODE_SINKHOLE_ALL)` closes the established `MODE_DNS` fd first and then fails (`establish() == null`).
     * Mutant: fail to recover `authorizedMode` on entry failure, or start the 1s hold anyway ->
     * `activeMode` stays `null` (child loses DNS filter) or `acknowledged` falsely claims `true`.
     */
    @Test
    fun `failed entry skips hold, immediately recovers authorized MODE_DNS, and does not acknowledge`() = runBlocking {
        val harness = SyntheticServiceHarness(
            onEstablish = { wanted, _ -> wanted != FilterVpnService.MODE_SINKHOLE_ALL },
        )

        val outcome = harness.controller.executeReset()

        assertEquals(WebFilterConnectionReset.TransitionOutcome.FAILED_ENTRY_RECOVERED, outcome)
        assertFalse("failed entry must not acknowledge transition", outcome.acknowledged)
        assertEquals("authorized MODE_DNS must be recovered after failed entry", FilterVpnService.MODE_DNS, harness.activeMode)
        assertEquals(
            listOf("open:sinkhole_all#1@0", "fail:sinkhole_all#1@0", "open:dns#1@0", "active:dns@0"),
            harness.log,
        )
    }

    /**
     * Synthetic service test 2 — Failed restore (retry recovery + unrecoverable close):
     * Mutant A: attempt `openMode(MODE_DNS)` only once with no retry -> transient failure leaves tunnel down.
     * Mutant B: leave `activeMode == MODE_SINKHOLE_ALL` when all restore retries fail -> child remains blackholed.
     */
    @Test
    fun `failed restore retries authorized MODE_DNS and closes transient tunnel if all retries fail`() = runBlocking {
        // Case A: first restore fails, second succeeds after 250ms retry backoff
        val recoverable = SyntheticServiceHarness(
            onEstablish = { wanted, attempt ->
                !(wanted == FilterVpnService.MODE_DNS && attempt == 1)
            },
        )
        val outcomeA = recoverable.controller.executeReset()
        assertEquals(WebFilterConnectionReset.TransitionOutcome.COMPLETED, outcomeA)
        assertTrue(outcomeA.acknowledged)
        assertEquals(FilterVpnService.MODE_DNS, recoverable.activeMode)
        assertEquals(
            listOf(
                "open:sinkhole_all#1@0",
                "active:sinkhole_all@0",
                "wait:1000@0",
                "open:dns#1@1000",
                "fail:dns#1@1000",
                "wait:250@1000",
                "open:dns#2@1250",
                "active:dns@1250",
            ),
            recoverable.log,
        )

        // Case B: all 3 restore attempts fail -> closeTunnel() tears down transient routing
        val unrecoverable = SyntheticServiceHarness(
            onEstablish = { wanted, _ -> wanted != FilterVpnService.MODE_DNS },
        )
        val outcomeB = unrecoverable.controller.executeReset()
        assertEquals(WebFilterConnectionReset.TransitionOutcome.RESTORE_FAILED_CLOSED, outcomeB)
        assertFalse(outcomeB.acknowledged)
        assertNull("transient sinkhole must be closed when restore cannot re-open DNS", unrecoverable.activeMode)
        assertEquals("close@1500", unrecoverable.log.last())
    }

    /**
     * Synthetic service test 3 — Delayed establishment & actual transition acknowledgment:
     * `establish(MODE_SINKHOLE_ALL)` takes 2,500 ms before becoming active.
     * Mutant: start the 1,000 ms timer at intent dispatch (`t = 0`) or acknowledge dispatch before restore ->
     * `MODE_DNS` fires at `1,000 ms` (before/during establishment) or deferred completes before `t = 3,500 ms`.
     */
    @Test
    fun `delayed establishment starts 1s hold only after sinkhole interface is active and acknowledges at end`() = runBlocking {
        val establishGate = CompletableDeferred<Unit>()
        val harness = SyntheticServiceHarness(
            onEstablish = { wanted, _ ->
                if (wanted == FilterVpnService.MODE_SINKHOLE_ALL) {
                    establishGate.await()
                    nowMs += 2_500L
                }
                true
            },
        )

        val deferredOutcome = async { harness.controller.executeReset() }
        yield()
        assertFalse("must not acknowledge while sinkhole establishment is still pending", deferredOutcome.isCompleted)

        establishGate.complete(Unit)
        val outcome = deferredOutcome.await()

        assertEquals(WebFilterConnectionReset.TransitionOutcome.COMPLETED, outcome)
        assertTrue(outcome.acknowledged)
        assertEquals(3_500L, harness.nowMs)
        assertEquals(
            listOf(
                "open:sinkhole_all#1@0",
                "active:sinkhole_all@2500",
                "wait:1000@2500",
                "open:dns#1@3500",
                "active:dns@3500",
            ),
            harness.log,
        )
    }

    /**
     * Synthetic service test 4 — Consent withdrawal vs deliberate Internet Pause during transient phase:
     * Mutant A: gate DNS restoration on `!consentPaused` -> consent withdrawal during transient sinkhole
     * skips cleanup and strands the child in `0.0.0.0/0` packet-dropping sinkhole mode!
     * Mutant B: fail to distinguish deliberate `pause_internet` (`authorizedMode == MODE_SINKHOLE_ALL`) ->
     * overwrites parent's Internet Pause back to `MODE_DNS`.
     */
    @Test
    fun `consent change cleans up transient sinkhole immediately while deliberate Internet Pause preserves sinkhole`() = runBlocking {
        // Case A: consent withdrawn mid-window -> interrupts hold and restores MODE_DNS cleanup
        val consentHarness = SyntheticServiceHarness(
            onWait = {
                nowMs += 200L
                consentPaused = true
                controller.interruptTransientHold()
            },
        )
        val consentOutcome = consentHarness.controller.executeReset()
        assertEquals(WebFilterConnectionReset.TransitionOutcome.CLEANED_UP_ON_CONSENT_CHANGE, consentOutcome)
        assertFalse(consentOutcome.acknowledged)
        assertEquals("transient sinkhole must be exited on consent withdrawal", FilterVpnService.MODE_DNS, consentHarness.activeMode)

        // Case B: deliberate pause_internet mid-window -> preserves MODE_SINKHOLE_ALL
        val pauseHarness = SyntheticServiceHarness(
            onWait = {
                nowMs += 300L
                internetPaused = true
                authorizedMode = FilterVpnService.MODE_SINKHOLE_ALL
                lockActive = true
                controller.interruptTransientHold()
            },
        )
        val pauseOutcome = pauseHarness.controller.executeReset()
        assertEquals(WebFilterConnectionReset.TransitionOutcome.SUPERSEDED_BY_PAUSE, pauseOutcome)
        assertTrue(pauseOutcome.acknowledged)
        assertEquals("deliberate pause_internet must stay in sinkhole_all", FilterVpnService.MODE_SINKHOLE_ALL, pauseHarness.activeMode)
    }

    /**
     * Source-wiring guard: `FilterVpnService` owns `TransientTunnelController` under its service lifetime,
     * awaits actual `TransitionOutcome` completion (`awaitConnectionReset`), separates `authorizedMode`
     * from transient `mode`, and touches neither `LockState.set`, `LockPeriodTracker`, nor `LockActivity`.
     */
    @Test
    fun `service owns TransientTunnelController and callers await actual transition without LockState drift`() {
        val dispatcher = stripComments(sourceFile("app/src/main/java/com/familyshield/agent/commands/CommandDispatcher.kt"))
        val rulesBranch = dispatcher.substringAfter("\"rules_updated\" ->").substringBefore("\"locate_now\" ->")
        assertTrue(rulesBranch.indexOf("val beforeWebFilter") in 0..<rulesBranch.indexOf("rules.refresh()"))
        assertTrue(rulesBranch.indexOf("WebFilterConnectionReset.resetIfNeeded(") > rulesBranch.indexOf("rules.refresh()"))
        assertFalse(rulesBranch.contains("LockState.set"))
        assertFalse(rulesBranch.contains("LockPeriodTracker"))
        assertFalse(rulesBranch.contains("LockActivity"))

        val helperCode = stripComments(sourceFile("app/src/main/java/com/familyshield/agent/vpn/WebFilterConnectionReset.kt"))
        assertFalse(helperCode.contains("LockState.set"))
        assertFalse(helperCode.contains("LockPeriodTracker"))
        assertFalse(helperCode.contains("LockActivity"))
        assertTrue("resetIfNeeded must await actual service transition", helperCode.contains("FilterVpnService.awaitConnectionReset("))

        val vpn = stripComments(sourceFile("app/src/main/java/com/familyshield/agent/vpn/FilterVpnService.kt"))
        assertTrue("FilterVpnService must own TransientTunnelController", vpn.contains("WebFilterConnectionReset.TransientTunnelController("))
        assertTrue("FilterVpnService must track separate authorizedMode", vpn.contains("authorizedMode = wanted"))
        assertTrue("FilterVpnService must handle ACTION_RESET_CONNECTIONS", vpn.contains("ACTION_RESET_CONNECTIONS"))
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