package com.familyshield.agent.vpn

import com.familyshield.agent.network.dto.WebFilterRuleDto
import java.io.File
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.async
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class WebFilterConnectionResetTest {

    private class SyntheticServiceHarness(
        var instanceId: Long = 1L,
        initialAuthorizedMode: String = FilterVpnService.MODE_DNS,
        var activeMode: String? = FilterVpnService.MODE_DNS,
        var internetPaused: Boolean = false,
        var consentPaused: Boolean = false,
        var lockActive: Boolean = false,
        initialStopping: Boolean = false,
        var committedPolicy: WebFilterConnectionReset.PolicySnapshot = WebFilterConnectionReset.PolicySnapshot(),
        val onEstablish: (SyntheticServiceHarness, String, Int, WebFilterConnectionReset.PolicySnapshot) -> Boolean = { _, _, _, _ -> true },
        val onWait: suspend SyntheticServiceHarness.(Long) -> Unit = { ms -> nowMs += ms },
    ) {
        var nowMs: Long = 0L
        val log = mutableListOf<String>()
        var appliedDnsConfig: DnsFilterPolicy.Config = committedPolicy.dnsConfig
        var appliedBypassApps: List<String> = committedPolicy.alwaysAllowedApps
        private val attemptCounts = mutableMapOf<String, Int>()
        private val serviceThreadMutex = Mutex()
        private var currentThreadOnService: Boolean = false

        val controller: WebFilterConnectionReset.TransientTunnelController

        init {
            controller = WebFilterConnectionReset.TransientTunnelController(
                serviceInstanceId = { if (controllerStopping) 0L else instanceId },
                serviceDispatcher = WebFilterConnectionReset.ServiceDispatcher { block ->
                    serviceThreadMutex.withLock {
                        currentThreadOnService = true
                        try {
                            block()
                        } finally {
                            currentThreadOnService = false
                        }
                    }
                },
                readCommittedPolicyOnServiceThread = {
                    assertTrue("policy read must run on service thread", currentThreadOnService)
                    committedPolicy
                },
                applyPolicyOnServiceThread = { snap ->
                    assertTrue("policy apply must run on service thread", currentThreadOnService)
                    appliedDnsConfig = snap.dnsConfig
                },
                activeModeOnServiceThread = {
                    assertTrue("activeMode read must run on service thread", currentThreadOnService)
                    activeMode
                },
                openModeOnServiceThread = { wanted, snap ->
                    assertTrue("openMode must run on service thread", currentThreadOnService)
                    activeMode = null
                    val n = (attemptCounts[wanted] ?: 0) + 1
                    attemptCounts[wanted] = n
                    log += "open:$wanted#$n@${nowMs}"
                    val ok = onEstablish(this, wanted, n, snap)
                    if (ok) {
                        activeMode = wanted
                        appliedBypassApps = snap.alwaysAllowedApps
                        log += "active:$wanted@${nowMs}"
                    } else {
                        log += "fail:$wanted#$n@${nowMs}"
                    }
                    ok
                },
                closeTunnelOnServiceThread = {
                    assertTrue("closeTunnel must run on service thread", currentThreadOnService)
                    activeMode = null
                    log += "close@${nowMs}"
                },
                isInternetPausedOnServiceThread = { internetPaused },
                isConsentPausedOnServiceThread = { consentPaused },
                isLockActiveOnServiceThread = { lockActive },
                waitMs = { ms ->
                    log += "wait:${ms}@${nowMs}"
                    onWait(ms)
                },
            )
            runBlocking {
                if (initialAuthorizedMode != FilterVpnService.MODE_DNS) {
                    serviceThreadMutex.withLock {
                        currentThreadOnService = true
                        try {
                            controller.handleAuthoritativeStartOnServiceThread(initialAuthorizedMode)
                        } finally {
                            currentThreadOnService = false
                        }
                    }
                    log.clear()
                    attemptCounts.clear()
                    activeMode = if (initialStopping) null else activeMode
                }
                if (initialStopping) {
                    serviceThreadMutex.withLock {
                        currentThreadOnService = true
                        try {
                            controller.handleServiceStopOnServiceThread()
                        } finally {
                            currentThreadOnService = false
                        }
                    }
                    log.clear()
                }
            }
        }

        private val controllerStopping: Boolean
            get() = controller.isStoppingOnServiceThread()

        suspend fun serviceAuthoritativeStart(wantedMode: String, pausedFlag: Boolean = wantedMode == FilterVpnService.MODE_SINKHOLE_ALL): Boolean =
            serviceThreadMutex.withLock {
                currentThreadOnService = true
                try {
                    internetPaused = pausedFlag
                    lockActive = pausedFlag
                    controller.handleAuthoritativeStartOnServiceThread(wantedMode)
                } finally {
                    currentThreadOnService = false
                }
            }

        suspend fun serviceConsentChanged(pausedNow: Boolean) =
            serviceThreadMutex.withLock {
                currentThreadOnService = true
                try {
                    consentPaused = pausedNow
                    if (pausedNow) internetPaused = false
                    controller.handleConsentChangedOnServiceThread(pausedNow)
                } finally {
                    currentThreadOnService = false
                }
            }

        suspend fun serviceStop() =
            serviceThreadMutex.withLock {
                currentThreadOnService = true
                try {
                    controller.handleServiceStopOnServiceThread()
                } finally {
                    currentThreadOnService = false
                }
            }
    }

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

    @Test
    fun `paused, locked, stopped, or unconsented states skip transition without touching tunnel`() = runBlocking {
        val states = listOf(
            SyntheticServiceHarness(internetPaused = true),
            SyntheticServiceHarness(lockActive = true),
            SyntheticServiceHarness(initialAuthorizedMode = FilterVpnService.MODE_SINKHOLE_ALL, activeMode = FilterVpnService.MODE_SINKHOLE_ALL),
            SyntheticServiceHarness(activeMode = FilterVpnService.MODE_SINKHOLE_ALL),
            SyntheticServiceHarness(activeMode = null),
            SyntheticServiceHarness(consentPaused = true),
            SyntheticServiceHarness(initialStopping = true, activeMode = null),
        )
        for (h in states) {
            val outcome = h.controller.executeReset(requestInstanceId = 1L)
            assertTrue(
                outcome == WebFilterConnectionReset.TransitionOutcome.SKIPPED ||
                    outcome == WebFilterConnectionReset.TransitionOutcome.EXPIRED_INSTANCE,
            )
            assertFalse(outcome.acknowledged)
            assertTrue("ineligible state must not touch tunnel: ${h.log}", h.log.isEmpty())
        }
    }

    @Test
    fun `failed entry skips hold, immediately recovers authorized MODE_DNS, and does not acknowledge`() = runBlocking {
        val harness = SyntheticServiceHarness(
            onEstablish = { _, wanted, _, _ -> wanted != FilterVpnService.MODE_SINKHOLE_ALL },
        )
        val outcome = harness.controller.executeReset()
        assertEquals(WebFilterConnectionReset.TransitionOutcome.FAILED_ENTRY_RECOVERED, outcome)
        assertFalse(outcome.acknowledged)
        assertEquals(FilterVpnService.MODE_DNS, harness.activeMode)
        assertEquals(
            listOf("open:sinkhole_all#1@0", "fail:sinkhole_all#1@0", "open:dns#1@0", "active:dns@0"),
            harness.log,
        )
    }

    @Test
    fun `failed restore retries authorized MODE_DNS and closes transient tunnel if all retries fail`() = runBlocking {
        val recoverable = SyntheticServiceHarness(
            onEstablish = { _, wanted, attempt, _ -> !(wanted == FilterVpnService.MODE_DNS && attempt == 1) },
        )
        val outcomeA = recoverable.controller.executeReset()
        assertEquals(WebFilterConnectionReset.TransitionOutcome.COMPLETED, outcomeA)
        assertTrue(outcomeA.acknowledged)
        assertEquals(FilterVpnService.MODE_DNS, recoverable.activeMode)
        assertEquals(
            listOf("open:sinkhole_all#1@0", "active:sinkhole_all@0", "wait:1000@0", "open:dns#1@1000", "fail:dns#1@1000", "wait:250@1000", "open:dns#2@1250", "active:dns@1250"),
            recoverable.log,
        )

        val unrecoverable = SyntheticServiceHarness(
            onEstablish = { _, wanted, _, _ -> wanted != FilterVpnService.MODE_DNS },
        )
        val outcomeB = unrecoverable.controller.executeReset()
        assertEquals(WebFilterConnectionReset.TransitionOutcome.RESTORE_FAILED_CLOSED, outcomeB)
        assertFalse(outcomeB.acknowledged)
        assertNull(unrecoverable.activeMode)
        assertEquals("close@1500", unrecoverable.log.last())
    }

    @Test
    fun `delayed establishment starts 1s hold only after sinkhole interface is active and acknowledges at end`() = runBlocking {
        var establishLatencySimulated = false
        val harness = SyntheticServiceHarness(
            onEstablish = { h, wanted, _, _ ->
                if (wanted == FilterVpnService.MODE_SINKHOLE_ALL && !establishLatencySimulated) {
                    establishLatencySimulated = true
                    h.nowMs += 2_500L
                }
                true
            },
        )
        val outcome = harness.controller.executeReset()
        assertEquals(WebFilterConnectionReset.TransitionOutcome.COMPLETED, outcome)
        assertTrue(outcome.acknowledged)
        assertEquals(3_500L, harness.nowMs)
        assertEquals(
            listOf("open:sinkhole_all#1@0", "active:sinkhole_all@2500", "wait:1000@2500", "open:dns#1@3500", "active:dns@3500"),
            harness.log,
        )
    }

    @Test
    fun `service pause, consent withdrawal, and stop transition immediately while hold is suspended without packet events`() = runBlocking {
        val holdEnteredA = CompletableDeferred<Unit>()
        val neverFiresTimerA = CompletableDeferred<Unit>()
        val pauseHarness = SyntheticServiceHarness(
            onWait = {
                nowMs = 150L
                holdEnteredA.complete(Unit)
                neverFiresTimerA.await()
            },
        )
        val resetJobA = async { pauseHarness.controller.executeReset() }
        holdEnteredA.await()
        assertFalse(resetJobA.isCompleted)

        assertTrue(pauseHarness.serviceAuthoritativeStart(FilterVpnService.MODE_SINKHOLE_ALL, pausedFlag = true))
        val outA = resetJobA.await()
        assertEquals(WebFilterConnectionReset.TransitionOutcome.SUPERSEDED_BY_PAUSE, outA)
        assertTrue(outA.acknowledged)
        assertEquals(150L, pauseHarness.nowMs)
        assertEquals(FilterVpnService.MODE_SINKHOLE_ALL, pauseHarness.activeMode)

        val holdEnteredB = CompletableDeferred<Unit>()
        val neverFiresTimerB = CompletableDeferred<Unit>()
        val consentHarness = SyntheticServiceHarness(
            onWait = {
                nowMs = 200L
                holdEnteredB.complete(Unit)
                neverFiresTimerB.await()
            },
        )
        val resetJobB = async { consentHarness.controller.executeReset() }
        holdEnteredB.await()
        assertFalse(resetJobB.isCompleted)

        consentHarness.serviceConsentChanged(pausedNow = true)
        assertEquals(FilterVpnService.MODE_DNS, consentHarness.activeMode)
        val outB = resetJobB.await()
        assertEquals(WebFilterConnectionReset.TransitionOutcome.CLEANED_UP_ON_CONSENT_CHANGE, outB)
        assertFalse(outB.acknowledged)
        assertEquals(200L, consentHarness.nowMs)
        assertEquals(FilterVpnService.MODE_DNS, consentHarness.activeMode)

        val holdEnteredC = CompletableDeferred<Unit>()
        val neverFiresTimerC = CompletableDeferred<Unit>()
        val stopHarness = SyntheticServiceHarness(
            onWait = {
                nowMs = 250L
                holdEnteredC.complete(Unit)
                neverFiresTimerC.await()
            },
        )
        val resetJobC = async { stopHarness.controller.executeReset() }
        holdEnteredC.await()
        assertFalse(resetJobC.isCompleted)

        stopHarness.serviceStop()
        assertNull(stopHarness.activeMode)
        val outC = resetJobC.await()
        assertEquals(WebFilterConnectionReset.TransitionOutcome.STOPPED, outC)
        assertFalse(outC.acknowledged)
        assertEquals(250L, stopHarness.nowMs)
        assertNull(stopHarness.activeMode)
    }

    @Test
    fun `failed pause establish never falsely returns SUPERSEDED_BY_PAUSE and fallback never closes a newer tunnel`() = runBlocking {
        val holdEntered = CompletableDeferred<Unit>()
        val neverTimer = CompletableDeferred<Unit>()
        var failSinkholeFromAttempt2 = false
        val failedPauseHarness = SyntheticServiceHarness(
            onEstablish = { _, wanted, attempt, _ ->
                !(wanted == FilterVpnService.MODE_SINKHOLE_ALL && failSinkholeFromAttempt2 && attempt >= 2)
            },
            onWait = { ms ->
                if (ms == 1_000L) {
                    nowMs = 100L
                    holdEntered.complete(Unit)
                    neverTimer.await()
                } else {
                    nowMs += ms
                }
            },
        )
        val jobA = async { failedPauseHarness.controller.executeReset() }
        holdEntered.await()
        failSinkholeFromAttempt2 = true
        failedPauseHarness.committedPolicy = WebFilterConnectionReset.PolicySnapshot(
            alwaysAllowedApps = listOf("com.school.portal"),
        )
        assertFalse(failedPauseHarness.serviceAuthoritativeStart(FilterVpnService.MODE_SINKHOLE_ALL, pausedFlag = true))

        val outA = jobA.await()
        assertEquals(WebFilterConnectionReset.TransitionOutcome.RESTORE_FAILED_CLOSED, outA)
        assertFalse(outA.acknowledged)
        assertNull(failedPauseHarness.activeMode)

        var allowAuthoritativeEstablish = false
        val newerTunnelHarness = SyntheticServiceHarness(
            onEstablish = { _, wanted, attempt, _ ->
                if (wanted == FilterVpnService.MODE_SINKHOLE_ALL && attempt == 1) true
                else allowAuthoritativeEstablish
            },
            onWait = { ms ->
                nowMs += ms
                if (ms == 250L && nowMs == 1_250L) {
                    allowAuthoritativeEstablish = true
                    serviceAuthoritativeStart(FilterVpnService.MODE_DNS, pausedFlag = false)
                    allowAuthoritativeEstablish = false
                }
            },
        )
        val outB = newerTunnelHarness.controller.executeReset()
        assertEquals(WebFilterConnectionReset.TransitionOutcome.COMPLETED, outB)
        assertEquals(FilterVpnService.MODE_DNS, newerTunnelHarness.activeMode)
        assertFalse(newerTunnelHarness.log.any { it.startsWith("close@") })
    }

    @Test
    fun `post-hop committed policy wins for web filter and SafeSearch and expired instance requests are dropped`() = runBlocking {
        val initialWf = WebFilterRuleDto(blockedDomains = listOf("old.example"))
        val updatedWf = WebFilterRuleDto(
            blockedDomains = listOf("old.example", "newlyblocked.example"),
            blockedCategories = listOf("adult"),
            safeSearchEnforced = true,
            youtubeRestrictedMode = "strict",
        )
        val harness = SyntheticServiceHarness(
            instanceId = 7L,
            committedPolicy = WebFilterConnectionReset.PolicySnapshot(
                dnsConfig = DnsFilterPolicy.Config(blockedDomains = listOf("old.example"), safeSearch = false, youtubeMode = "off"),
                alwaysAllowedApps = emptyList(),
                webFilter = initialWf,
            ),
            onWait = { ms ->
                nowMs += ms
                if (ms == 1_000L) {
                    committedPolicy = WebFilterConnectionReset.PolicySnapshot(
                        dnsConfig = DnsFilterPolicy.Config(
                            blockedDomains = listOf("old.example", "newlyblocked.example"),
                            blockedCategories = listOf("adult"),
                            safeSearch = true,
                            youtubeMode = "strict",
                        ),
                        alwaysAllowedApps = listOf("com.khanacademy.android"),
                        webFilter = updatedWf,
                    )
                }
            },
        )

        val out = harness.controller.executeReset(requestInstanceId = 7L)
        assertEquals(WebFilterConnectionReset.TransitionOutcome.COMPLETED, out)
        assertTrue(out.acknowledged)
        assertEquals(FilterVpnService.MODE_DNS, harness.activeMode)
        assertEquals(listOf("old.example", "newlyblocked.example"), harness.appliedDnsConfig.blockedDomains)
        assertEquals(listOf("adult"), harness.appliedDnsConfig.blockedCategories)
        assertTrue(harness.appliedDnsConfig.safeSearch)
        assertEquals("strict", harness.appliedDnsConfig.youtubeMode)
        assertEquals(listOf("com.khanacademy.android"), harness.appliedBypassApps)

        harness.instanceId = 8L
        harness.log.clear()
        val expiredOut = harness.controller.executeReset(requestInstanceId = 7L)
        assertEquals(WebFilterConnectionReset.TransitionOutcome.EXPIRED_INSTANCE, expiredOut)
        assertFalse(expiredOut.acknowledged)
        assertTrue(harness.log.isEmpty())
    }

    @Test
    fun `service owns TransientTunnelController, stamps instanceId, wires immediate consent callback, and avoids LockState drift`() {
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
        assertTrue(helperCode.contains("FilterVpnService.awaitConnectionReset("))

        val vpn = stripComments(sourceFile("app/src/main/java/com/familyshield/agent/vpn/FilterVpnService.kt"))
        assertTrue(vpn.contains("WebFilterConnectionReset.TransientTunnelController("))
        assertTrue(vpn.contains("EXTRA_TARGET_INSTANCE_ID"))
        assertTrue(vpn.contains("handleAuthoritativeStartOnServiceThread("))
        assertTrue(vpn.contains("handleConsentChangedOnServiceThread("))
        assertTrue(vpn.contains("handleServiceStopOnServiceThread()"))

        val consentCode = stripComments(sourceFile("app/src/main/java/com/familyshield/agent/data/ConsentState.kt"))
        assertTrue(consentCode.contains("FilterVpnService.onConsentChanged("))
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
