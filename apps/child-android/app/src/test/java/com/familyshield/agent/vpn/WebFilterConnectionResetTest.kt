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
        var liveInstanceId: Long? = null,
        initialAuthorizedMode: String = FilterVpnService.MODE_DNS,
        var activeMode: String? = FilterVpnService.MODE_DNS,
        var internetPaused: Boolean = false,
        var consentPaused: Boolean = false,
        var lockActive: Boolean = false,
        var vpnEnabled: Boolean = true,
        var paired: Boolean = true,
        var consentEpoch: Long = 0L,
        initialStopping: Boolean = false,
        var committedPolicy: WebFilterConnectionReset.PolicySnapshot = WebFilterConnectionReset.PolicySnapshot(),
        val onEstablish: (SyntheticServiceHarness, String, Int, WebFilterConnectionReset.PolicySnapshot) -> Boolean = { _, _, _, _ -> true },
        val onPreparePolicy: suspend SyntheticServiceHarness.(Int) -> Unit = {},
        val onReadPolicy: SyntheticServiceHarness.() -> WebFilterConnectionReset.PolicySnapshot = { this.committedPolicy },
        val onApplyPolicy: SyntheticServiceHarness.(WebFilterConnectionReset.PolicySnapshot) -> Unit = {},
        val onWait: suspend SyntheticServiceHarness.(Long) -> Unit = { ms -> nowMs += ms },
    ) {
        var nowMs: Long = 0L
        val log = mutableListOf<String>()
        var appliedDnsConfig: DnsFilterPolicy.Config = committedPolicy.dnsConfig
        var appliedBypassApps: List<String> = committedPolicy.alwaysAllowedApps
        var persistedVpnMode: String = initialAuthorizedMode
        var hadEstablishedTunnel: Boolean = activeMode != null
        var recordedLossEpoch: Long? = null
        var lossAlertsEnqueued: Int = 0
        val terminalLossOutcomes = mutableListOf<WebFilterConnectionReset.TransitionOutcome>()
        val scheduledAuthoritativeRestarts = mutableListOf<Pair<Long, String>>()
        val pendingRestartTasks = ArrayDeque<Pair<Long, Long>>()
        var prepareCalls: Int = 0
        val isFilterLost: Boolean
            get() = FilterLossPolicy.isLost(
                recordedEpoch = recordedLossEpoch,
                enabled = vpnEnabled,
                paired = paired,
                consentPaused = consentPaused,
                consentEpoch = consentEpoch,
            )
        var beforeServiceDispatch: (() -> Unit)? = null
        private val attemptCounts = mutableMapOf<String, Int>()
        private val serviceThreadMutex = Mutex()
        private var currentThreadOnService: Boolean = false

        val controller: WebFilterConnectionReset.TransientTunnelController

        private fun effectiveLiveInstanceId(): Long = liveInstanceId ?: instanceId

        init {
            controller = WebFilterConnectionReset.TransientTunnelController(
                serviceInstanceId = {
                    if (controllerStopping || effectiveLiveInstanceId() != instanceId) 0L else instanceId
                },
                serviceDispatcher = WebFilterConnectionReset.ServiceDispatcher { block ->
                    beforeServiceDispatch?.invoke()
                    serviceThreadMutex.withLock {
                        currentThreadOnService = true
                        try {
                            block()
                        } finally {
                            currentThreadOnService = false
                        }
                    }
                },
                prepareCommittedPolicy = {
                    prepareCalls += 1
                    onPreparePolicy(prepareCalls)
                },
                readCommittedPolicyOnServiceThread = {
                    assertTrue("policy read must run on service thread", currentThreadOnService)
                    onReadPolicy()
                },
                applyPolicyOnServiceThread = { snap ->
                    assertTrue("policy apply must run on service thread", currentThreadOnService)
                    onApplyPolicy(snap)
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
                        hadEstablishedTunnel = true
                        recordedLossEpoch = null
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
                onTerminalTunnelLossOnServiceThread = { expectedInstanceId, authorityEpoch, terminalOutcome ->
                    assertTrue("terminal loss handler must run on service thread", currentThreadOnService)
                    if (!controllerStopping &&
                        (terminalOutcome == WebFilterConnectionReset.TransitionOutcome.FAILED_ENTRY_CLOSED ||
                            terminalOutcome == WebFilterConnectionReset.TransitionOutcome.RESTORE_FAILED_CLOSED) &&
                        expectedInstanceId > 0L &&
                        expectedInstanceId == instanceId &&
                        effectiveLiveInstanceId() == instanceId &&
                        activeMode == null
                    ) {
                        terminalLossOutcomes += terminalOutcome
                        val wasEstablished = hadEstablishedTunnel
                        hadEstablishedTunnel = false
                        if (FilterLossPolicy.shouldRecord(
                                recordedEpoch = recordedLossEpoch,
                                wasEstablished = wasEstablished,
                                enabled = vpnEnabled,
                                paired = paired,
                                consentPaused = consentPaused,
                                consentEpoch = consentEpoch,
                            )
                        ) {
                            recordedLossEpoch = consentEpoch
                            lossAlertsEnqueued += 1
                        }
                        if (vpnEnabled && !consentPaused) {
                            scheduledAuthoritativeRestarts += (instanceId to persistedVpnMode)
                            pendingRestartTasks.addLast(instanceId to authorityEpoch)
                        }
                    }
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
                    persistedVpnMode = wantedMode
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

        suspend fun executeNextScheduledRestart(): Boolean {
            val (expectedInstance, expectedAuthorityEpoch) = pendingRestartTasks.removeFirstOrNull() ?: return false
            return serviceThreadMutex.withLock {
                currentThreadOnService = true
                try {
                    if (!controllerStopping &&
                        effectiveLiveInstanceId() == expectedInstance &&
                        activeMode == null &&
                        vpnEnabled &&
                        !consentPaused
                    ) {
                        controller.executeScheduledRestartOnServiceThread(
                            expectedInstanceId = expectedInstance,
                            expectedAuthorityEpoch = expectedAuthorityEpoch,
                        )
                    } else {
                        false
                    }
                } finally {
                    currentThreadOnService = false
                }
            }
        }
    }

    // Mutant: omitting the SafeSearch comparison leaves the policy update without a reset.
    @Test
    fun `changing SafeSearch in either direction uses the shared reset`() = runBlocking {
        val off = WebFilterRuleDto(safeSearchEnforced = false)
        val on = off.copy(safeSearchEnforced = true)
        for ((before, after) in listOf(off to on, on to off)) {
            assertTrue(WebFilterConnectionReset.shouldResetConnections(before, after))
            val previousPolicy = WebFilterConnectionReset.PolicySnapshot(
                dnsConfig = DnsFilterPolicy.Config(safeSearch = before.safeSearchEnforced),
                webFilter = before,
            )
            val harness = SyntheticServiceHarness(committedPolicy = previousPolicy)
            harness.committedPolicy = previousPolicy.copy(
                dnsConfig = previousPolicy.dnsConfig.copy(safeSearch = after.safeSearchEnforced),
                webFilter = after,
            )
            val outcome = harness.controller.executeReset()

            assertEquals(WebFilterConnectionReset.TransitionOutcome.COMPLETED, outcome)
            assertEquals(after.safeSearchEnforced, harness.appliedDnsConfig.safeSearch)
            assertEquals(FilterVpnService.MODE_DNS, harness.activeMode)
            assertEquals(
                listOf("open:sinkhole_all#1@0", "active:sinkhole_all@0", "wait:1000@0", "open:dns#1@1000", "active:dns@1000"),
                harness.log,
            )
        }
    }

    // Mutant: treating a missing prior snapshot as SafeSearch off adds a reset at startup.
    @Test
    fun `initial and unchanged SafeSearch snapshots need no extra reset`() {
        val on = WebFilterRuleDto(safeSearchEnforced = true)

        assertFalse(WebFilterConnectionReset.shouldResetConnections(null, on))
        assertFalse(WebFilterConnectionReset.shouldResetConnections(on, null))
        assertFalse(WebFilterConnectionReset.shouldResetConnections(on, on.copy()))
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
    fun `terminal restore or entry failure records filter loss once and schedules authoritative MODE_DNS restart`() = runBlocking {
        // Mutant A: omit onTerminalTunnelLossOnServiceThread on RESTORE_FAILED_CLOSED / FAILED_ENTRY_CLOSED ->
        // tunnel closes silently with isFilterLost == false, 0 alerts enqueued, and 0 authoritative restarts scheduled.
        // Mutant B: enqueue alert unconditionally without FilterLossPolicy.shouldRecord / hadEstablishedTunnel ->
        // repeated loss within the same consent epoch enqueues >1 alert.
        val restoreFailed = SyntheticServiceHarness(
            onEstablish = { _, wanted, _, _ -> wanted != FilterVpnService.MODE_DNS },
        )
        val outRestore = restoreFailed.controller.executeReset()
        assertEquals(WebFilterConnectionReset.TransitionOutcome.RESTORE_FAILED_CLOSED, outRestore)
        assertFalse(outRestore.acknowledged)
        assertNull(restoreFailed.activeMode)
        assertTrue("filter loss must be active after RESTORE_FAILED_CLOSED", restoreFailed.isFilterLost)
        assertEquals(1, restoreFailed.lossAlertsEnqueued)
        assertEquals(listOf(1L to FilterVpnService.MODE_DNS), restoreFailed.scheduledAuthoritativeRestarts)

        // Follow-up failure without any intermediate tunnel establishment (e.g. subsequent revoke or failed entry
        // while recordedLossEpoch == consentEpoch) keeps isFilterLost == true and never enqueues a second alert.
        var failEverythingNow = false
        val entryFailed = SyntheticServiceHarness(
            onEstablish = { _, wanted, _, _ ->
                if (failEverythingNow) false else wanted != FilterVpnService.MODE_DNS && false
            },
        )
        val outEntry = entryFailed.controller.executeReset()
        assertEquals(WebFilterConnectionReset.TransitionOutcome.FAILED_ENTRY_CLOSED, outEntry)
        assertFalse(outEntry.acknowledged)
        assertNull(entryFailed.activeMode)
        assertTrue("filter loss must be active after FAILED_ENTRY_CLOSED", entryFailed.isFilterLost)
        assertEquals(1, entryFailed.lossAlertsEnqueued)
        assertEquals(listOf(1L to FilterVpnService.MODE_DNS), entryFailed.scheduledAuthoritativeRestarts)

        // Even if another failure arrives in the same consent epoch without an established tunnel clearing loss,
        // FilterLossPolicy.shouldRecord preserves single-alert behavior (still 1 alert).
        failEverythingNow = true
        entryFailed.activeMode = FilterVpnService.MODE_DNS
        entryFailed.hadEstablishedTunnel = true
        val secondEntryOut = entryFailed.controller.executeReset()
        assertEquals(WebFilterConnectionReset.TransitionOutcome.FAILED_ENTRY_CLOSED, secondEntryOut)
        assertTrue(entryFailed.isFilterLost)
        assertEquals("single-alert invariant within one consent epoch", 1, entryFailed.lossAlertsEnqueued)
    }

    @Test
    fun `replaced service instance or newer successful authoritative restore cannot emit stale filter loss`() = runBlocking {
        // Mutant A: fail to fence terminal failure against effective live service instance ->
        // superseded instance #7 emits filter loss / alert after instance #8 already took over.
        val replacedHarness = SyntheticServiceHarness(
            instanceId = 7L,
            onEstablish = { _, wanted, _, _ -> wanted != FilterVpnService.MODE_DNS },
            onWait = { ms ->
                nowMs += ms
                if (ms == 250L) {
                    // Instance #8 replaced instance #7 while retry backoff was in progress.
                    liveInstanceId = 8L
                }
            },
        )
        val replacedOut = replacedHarness.controller.executeReset(requestInstanceId = 7L)
        assertEquals(WebFilterConnectionReset.TransitionOutcome.EXPIRED_INSTANCE, replacedOut)
        assertFalse(replacedOut.acknowledged)
        assertFalse("replaced service instance must not emit filter loss", replacedHarness.isFilterLost)
        assertEquals(0, replacedHarness.lossAlertsEnqueued)
        assertTrue(replacedHarness.scheduledAuthoritativeRestarts.isEmpty())

        // Mutant B: emit terminal loss after retry loop exits without checking whether a newer authoritative
        // restore succeeded before terminal service-thread finalization -> false loss alert on an active tunnel.
        var dnsAttempts = 0
        var allowAuthoritative = false
        var restoredRightAfterLastRetry = false
        lateinit var newerRestoreHarness: SyntheticServiceHarness
        newerRestoreHarness = SyntheticServiceHarness(
            instanceId = 9L,
            onEstablish = { _, wanted, _, _ ->
                if (wanted == FilterVpnService.MODE_SINKHOLE_ALL) {
                    true
                } else if (allowAuthoritative) {
                    true
                } else {
                    dnsAttempts += 1
                    false
                }
            },
        )
        newerRestoreHarness.beforeServiceDispatch = {
            if (dnsAttempts == WebFilterConnectionReset.DEFAULT_RESTORE_RETRIES && !restoredRightAfterLastRetry) {
                restoredRightAfterLastRetry = true
                newerRestoreHarness.beforeServiceDispatch = null
                allowAuthoritative = true
                runBlocking {
                    assertTrue(newerRestoreHarness.serviceAuthoritativeStart(FilterVpnService.MODE_DNS, pausedFlag = false))
                }
                allowAuthoritative = false
            }
        }
        val newerOut = newerRestoreHarness.controller.executeReset(requestInstanceId = 9L)
        assertEquals(WebFilterConnectionReset.TransitionOutcome.COMPLETED, newerOut)
        assertEquals(FilterVpnService.MODE_DNS, newerRestoreHarness.activeMode)
        assertFalse("newer successful restore must not emit old filter loss", newerRestoreHarness.isFilterLost)
        assertEquals(0, newerRestoreHarness.lossAlertsEnqueued)
        assertTrue(newerRestoreHarness.scheduledAuthoritativeRestarts.isEmpty())
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

        // Mutant: omit handleTerminalResetLossOnMain wiring, instance fence, recordFilterLoss guard, or start(this, VpnState.mode(this)).
        val vpn = stripComments(sourceFile("app/src/main/java/com/familyshield/agent/vpn/FilterVpnService.kt"))
        assertTrue(vpn.contains("WebFilterConnectionReset.TransientTunnelController("))
        assertTrue(vpn.contains("EXTRA_TARGET_INSTANCE_ID"))
        assertTrue(vpn.contains("handleAuthoritativeStartOnServiceThread("))
        assertTrue(vpn.contains("handleConsentChangedOnServiceThread("))
        assertTrue(vpn.contains("handleServiceStopOnServiceThread()"))
        assertTrue(vpn.contains("onTerminalTunnelLossOnServiceThread"))
        val terminalHandler = vpn.substringAfter("private fun handleTerminalResetLossOnMain(").substringBefore("companion object")
        assertTrue(terminalHandler.contains("currentInstanceId != instanceId"))
        assertTrue(terminalHandler.contains("activeInstance !== this"))
        assertTrue(terminalHandler.contains("tunnelMode != null"))
        assertTrue(
            Regex(
                """if \(VpnState\.recordFilterLoss\(this, settings, consent, hadEstablishedTunnel\.getAndSet\(false\)\)\) \{\s+""" +
                    """TamperAlertWorker\.enqueue\(this, TamperAlertWorker\.TYPE_VPN_REVOKED\)""",
            ).containsMatchIn(terminalHandler),
        )
        assertTrue(terminalHandler.contains("transientResetController.executeScheduledRestartOnServiceThread("))
        assertTrue(terminalHandler.contains("expectedInstanceId = restartInstanceId"))
        assertTrue(terminalHandler.contains("expectedAuthorityEpoch = authorityEpoch"))

        val consentCode = stripComments(sourceFile("app/src/main/java/com/familyshield/agent/data/ConsentState.kt"))
        assertTrue(consentCode.contains("FilterVpnService.onConsentChanged("))
    }

    @Test
    fun `final policy refresh reopen failure routes through bounded restore and terminal loss handler`() = runBlocking {
        // Mutant A: ignore failed openModeOnServiceThread during final post-hop policy refresh ->
        // returns COMPLETED (acknowledged = true) with activeMode == null, isFilterLost == false, and 0 alerts.
        // Subcase 1: reopen fails once, then recovers via bounded restore retries -> COMPLETED with new bypass list.
        val recoverableReopen = SyntheticServiceHarness(
            onPreparePolicy = { callIndex ->
                if (callIndex == 3) {
                    committedPolicy = WebFilterConnectionReset.PolicySnapshot(
                        alwaysAllowedApps = listOf("com.khanacademy.android"),
                    )
                }
            },
            onEstablish = { _, wanted, attempt, _ ->
                // DNS attempt #1 is post-window restore (succeeds); DNS attempt #2 is post-hop reopen (fails);
                // DNS attempt #3 is bounded retry #1 (succeeds).
                !(wanted == FilterVpnService.MODE_DNS && attempt == 2)
            },
        )
        val recOut = recoverableReopen.controller.executeReset()
        assertEquals(WebFilterConnectionReset.TransitionOutcome.COMPLETED, recOut)
        assertTrue(recOut.acknowledged)
        assertEquals(FilterVpnService.MODE_DNS, recoverableReopen.activeMode)
        assertEquals(listOf("com.khanacademy.android"), recoverableReopen.appliedBypassApps)
        assertFalse(recoverableReopen.isFilterLost)
        assertEquals(0, recoverableReopen.lossAlertsEnqueued)

        // Subcase 2: post-hop reopen and all bounded retries fail -> RESTORE_FAILED_CLOSED, 1 alert, guarded restart.
        var allowScheduledRecovery = false
        val terminalReopen = SyntheticServiceHarness(
            onPreparePolicy = { callIndex ->
                if (callIndex == 3) {
                    committedPolicy = WebFilterConnectionReset.PolicySnapshot(
                        alwaysAllowedApps = listOf("com.duolingo"),
                    )
                }
            },
            onEstablish = { _, wanted, attempt, _ ->
                if (wanted == FilterVpnService.MODE_SINKHOLE_ALL) true
                else if (attempt == 1) true
                else allowScheduledRecovery
            },
        )
        val termOut = terminalReopen.controller.executeReset()
        assertEquals(WebFilterConnectionReset.TransitionOutcome.RESTORE_FAILED_CLOSED, termOut)
        assertFalse("failed final-refresh reopen must never return acknowledged COMPLETED", termOut.acknowledged)
        assertNull(terminalReopen.activeMode)
        assertTrue(terminalReopen.isFilterLost)
        assertEquals(1, terminalReopen.lossAlertsEnqueued)
        assertEquals(1, terminalReopen.pendingRestartTasks.size)

        allowScheduledRecovery = true
        assertTrue(terminalReopen.executeNextScheduledRestart())
        assertEquals(FilterVpnService.MODE_DNS, terminalReopen.activeMode)
        assertEquals(listOf("com.duolingo"), terminalReopen.appliedBypassApps)
        assertFalse(terminalReopen.isFilterLost)
    }

    @Test
    fun `scheduled authoritative restart enforces execution-time instance and authority checks`() = runBlocking {
        // Mutant A: capture mode at scheduling time or skip execution-time authority epoch check ->
        // queued restart overwrites a newer pause_internet or consent transition that took ownership.
        var allowEstablish = false
        val newerCommandHarness = SyntheticServiceHarness(
            onEstablish = { _, wanted, attempt, _ ->
                if (wanted == FilterVpnService.MODE_SINKHOLE_ALL && attempt == 1) true else allowEstablish
            },
        )
        val outA = newerCommandHarness.controller.executeReset()
        assertEquals(WebFilterConnectionReset.TransitionOutcome.RESTORE_FAILED_CLOSED, outA)
        assertEquals(1, newerCommandHarness.pendingRestartTasks.size)

        // A newer pause_internet command takes ownership BEFORE the queued restart runs (even if establish fails!).
        allowEstablish = false
        assertFalse(newerCommandHarness.serviceAuthoritativeStart(FilterVpnService.MODE_SINKHOLE_ALL, pausedFlag = true))
        allowEstablish = true
        // Now the older scheduled restart runs — its authority epoch is stale, so it MUST NOT execute!
        assertFalse(
            "stale scheduled restart must be rejected after newer command took ownership",
            newerCommandHarness.executeNextScheduledRestart(),
        )

        // Mutant B: skip execution-time live-instance check -> queued restart runs on superseded service instance.
        var allowReplacedEstablish = false
        val replacedRestartHarness = SyntheticServiceHarness(
            instanceId = 11L,
            onEstablish = { _, wanted, _, _ ->
                if (wanted == FilterVpnService.MODE_SINKHOLE_ALL) true else allowReplacedEstablish
            },
        )
        val outB = replacedRestartHarness.controller.executeReset(requestInstanceId = 11L)
        assertEquals(WebFilterConnectionReset.TransitionOutcome.RESTORE_FAILED_CLOSED, outB)
        assertEquals(1, replacedRestartHarness.pendingRestartTasks.size)

        replacedRestartHarness.liveInstanceId = 12L
        allowReplacedEstablish = true
        assertFalse(
            "scheduled restart from superseded instance must be rejected at execution time",
            replacedRestartHarness.executeNextScheduledRestart(),
        )
        assertNull(replacedRestartHarness.activeMode)
    }

    @Test
    fun `exceptional terminal path releases only failing reset ownership, preserves newer authority, and passes typed outcome`() = runBlocking {
        // Mutant A: fail to release transientTunnelEpoch / currentDelaySignal when an injected restore dependency throws ->
        // activeTransientEpochOnServiceThread() stays non-null and executeNextScheduledRestart() returns false, leaving VPN down.
        // Mutant B: clear transientTunnelEpoch / currentDelaySignal unconditionally without matching ownedEpoch / ownedSignal or
        // overwrite tunnelEpoch -> clobbers a newer owner's marker/signal or reverts newer pause_internet authority.
        // Mutant C: hardcode RESTORE_FAILED_CLOSED instead of passing/returning the current typed terminal outcome ->
        // FAILED_ENTRY_CLOSED or SUPERSEDED_BY_PAUSE is misreported to the service.

        // 1. Failing restore dependency (and hold interruption) releases this reset's marker & signal, closes transient
        //    sinkhole, passes RESTORE_FAILED_CLOSED, and allows the scheduled recovery restart to succeed.
        var throwOnApply = false
        var throwOnHold = true
        var observedDuringHoldEpoch: Long? = null
        var observedDuringHoldSignal: CompletableDeferred<Unit>? = null
        val restoreExceptionHarness = SyntheticServiceHarness(
            onApplyPolicy = {
                if (throwOnApply) throw IllegalStateException("injected applyPolicy failure")
            },
            onWait = { ms ->
                nowMs += ms
                if (ms == 1_000L && throwOnHold) {
                    observedDuringHoldEpoch = controller.activeTransientEpochOnServiceThread()
                    observedDuringHoldSignal = controller.activeDelaySignalOnServiceThread()
                    throwOnApply = true
                    throw IllegalStateException("injected hold failure")
                }
            },
        )
        val outRestoreEx = restoreExceptionHarness.controller.executeReset()
        assertEquals(1L, observedDuringHoldEpoch)
        assertTrue(observedDuringHoldSignal != null && observedDuringHoldSignal!!.isCompleted)
        assertEquals(WebFilterConnectionReset.TransitionOutcome.RESTORE_FAILED_CLOSED, outRestoreEx)
        assertFalse(outRestoreEx.acknowledged)
        assertNull("failing reset must release its transient epoch marker", restoreExceptionHarness.controller.activeTransientEpochOnServiceThread())
        assertNull("failing reset must release its delay signal", restoreExceptionHarness.controller.activeDelaySignalOnServiceThread())
        assertNull("transient sinkhole must be closed on exceptional restore failure", restoreExceptionHarness.activeMode)
        assertEquals(
            listOf(WebFilterConnectionReset.TransitionOutcome.RESTORE_FAILED_CLOSED),
            restoreExceptionHarness.terminalLossOutcomes,
        )
        assertTrue(restoreExceptionHarness.isFilterLost)
        assertEquals(1, restoreExceptionHarness.lossAlertsEnqueued)

        throwOnApply = false
        throwOnHold = false
        assertTrue(
            "scheduled recovery restart must succeed once failing reset released ownership",
            restoreExceptionHarness.executeNextScheduledRestart(),
        )
        assertEquals(FilterVpnService.MODE_DNS, restoreExceptionHarness.activeMode)
        assertFalse(restoreExceptionHarness.isFilterLost)

        // 2. Failing failed-entry recovery passes and returns FAILED_ENTRY_CLOSED (not hardcoded RESTORE_FAILED_CLOSED).
        var failSinkholeEntry = true
        var throwOnEntryRecoveryRead = false
        val entryExceptionHarness = SyntheticServiceHarness(
            onEstablish = { _, wanted, _, _ ->
                if (wanted == FilterVpnService.MODE_SINKHOLE_ALL && failSinkholeEntry) {
                    throwOnEntryRecoveryRead = true
                    false
                } else {
                    true
                }
            },
            onReadPolicy = {
                if (throwOnEntryRecoveryRead) throw IllegalStateException("injected readPolicy failure on entry recovery")
                committedPolicy
            },
        )
        val outEntryEx = entryExceptionHarness.controller.executeReset()
        assertEquals(WebFilterConnectionReset.TransitionOutcome.FAILED_ENTRY_CLOSED, outEntryEx)
        assertEquals(
            listOf(WebFilterConnectionReset.TransitionOutcome.FAILED_ENTRY_CLOSED),
            entryExceptionHarness.terminalLossOutcomes,
        )
        assertNull(entryExceptionHarness.controller.activeTransientEpochOnServiceThread())
        throwOnEntryRecoveryRead = false
        failSinkholeEntry = false
        assertTrue(entryExceptionHarness.executeNextScheduledRestart())
        assertEquals(FilterVpnService.MODE_DNS, entryExceptionHarness.activeMode)

        // 3. Newer authority preservation: if pause_internet took ownership before restore throws, newer authority epoch
        //    and active MODE_SINKHOLE_ALL tunnel are preserved once current policy read/apply succeeds.
        var throwOnceOnRestoreRead = false
        val newerActiveAuthority = SyntheticServiceHarness(
            onReadPolicy = {
                if (throwOnceOnRestoreRead) {
                    throwOnceOnRestoreRead = false
                    throw IllegalStateException("injected readPolicy failure after newer pause")
                }
                this.committedPolicy
            },
            onWait = { ms ->
                nowMs += ms
                if (ms == 1_000L) {
                    assertTrue(serviceAuthoritativeStart(FilterVpnService.MODE_SINKHOLE_ALL, pausedFlag = true))
                    throwOnceOnRestoreRead = true
                }
            },
        )
        val outSuperseded = newerActiveAuthority.controller.executeReset()
        assertEquals(WebFilterConnectionReset.TransitionOutcome.SUPERSEDED_BY_PAUSE, outSuperseded)
        assertEquals(2L, newerActiveAuthority.controller.currentAuthorityEpochOnServiceThread())
        assertEquals(FilterVpnService.MODE_SINKHOLE_ALL, newerActiveAuthority.activeMode)
        assertTrue(newerActiveAuthority.terminalLossOutcomes.isEmpty())
        assertFalse(newerActiveAuthority.isFilterLost)

        // 3b. Active DNS tunnel with failing current-policy read or apply on fallback must keep existing authority and
        //     tunnel intact while returning an unacknowledged outcome (POLICY_APPLY_FAILED), never COMPLETED.
        val olderPolicy = WebFilterConnectionReset.PolicySnapshot(
            dnsConfig = DnsFilterPolicy.Config(blockedDomains = listOf("older.example")),
        )
        val unappliedPolicy = WebFilterConnectionReset.PolicySnapshot(
            dnsConfig = DnsFilterPolicy.Config(blockedDomains = listOf("older.example", "new-unapplied.example")),
        )
        var failCurrentPolicyRead = false
        val failedReadOnActiveDns = SyntheticServiceHarness(
            committedPolicy = olderPolicy,
            onReadPolicy = {
                if (failCurrentPolicyRead) throw IllegalStateException("injected current-policy read failure")
                this.committedPolicy
            },
            onWait = { ms ->
                nowMs += ms
                if (ms == 1_000L) {
                    assertTrue(serviceAuthoritativeStart(FilterVpnService.MODE_DNS, pausedFlag = false))
                    committedPolicy = unappliedPolicy
                    failCurrentPolicyRead = true
                }
            },
        )
        val outFailedRead = failedReadOnActiveDns.controller.executeReset()
        assertEquals(WebFilterConnectionReset.TransitionOutcome.POLICY_APPLY_FAILED, outFailedRead)
        assertFalse("failed current-policy read must not return acknowledged outcome", outFailedRead.acknowledged)
        assertEquals(2L, failedReadOnActiveDns.controller.currentAuthorityEpochOnServiceThread())
        assertNull(failedReadOnActiveDns.controller.activeTransientEpochOnServiceThread())
        assertEquals(FilterVpnService.MODE_DNS, failedReadOnActiveDns.activeMode)
        assertEquals(listOf("older.example"), failedReadOnActiveDns.appliedDnsConfig.blockedDomains)
        assertTrue(failedReadOnActiveDns.terminalLossOutcomes.isEmpty())
        assertFalse(failedReadOnActiveDns.isFilterLost)

        var failCurrentPolicyApply = false
        val failedApplyOnPostHopDns = SyntheticServiceHarness(
            committedPolicy = olderPolicy,
            onPreparePolicy = { callIndex ->
                if (callIndex == 3) {
                    committedPolicy = unappliedPolicy
                    failCurrentPolicyApply = true
                }
            },
            onApplyPolicy = {
                if (failCurrentPolicyApply) throw IllegalStateException("injected current-policy apply failure")
            },
        )
        val outFailedApply = failedApplyOnPostHopDns.controller.executeReset()
        assertEquals(WebFilterConnectionReset.TransitionOutcome.POLICY_APPLY_FAILED, outFailedApply)
        assertFalse("failed current-policy apply must not return acknowledged outcome", outFailedApply.acknowledged)
        assertEquals(1L, failedApplyOnPostHopDns.controller.currentAuthorityEpochOnServiceThread())
        assertNull(failedApplyOnPostHopDns.controller.activeTransientEpochOnServiceThread())
        assertEquals(FilterVpnService.MODE_DNS, failedApplyOnPostHopDns.activeMode)
        assertEquals(listOf("older.example"), failedApplyOnPostHopDns.appliedDnsConfig.blockedDomains)
        assertTrue(failedApplyOnPostHopDns.terminalLossOutcomes.isEmpty())
        assertFalse(failedApplyOnPostHopDns.isFilterLost)

        // 4. Ownership-only release: if a newer owner's transient marker and delay signal are installed when the
        //    failing reset's exceptional cleanup executes, ONLY the failing reset's signal is completed and the newer
        //    owner's marker (epoch 99L) and signal remain untouched.
        var injectNewerTransientOwner = false
        val newerOwnerSignal = CompletableDeferred<Unit>()
        var failingResetSignal: CompletableDeferred<Unit>? = null
        lateinit var ownershipIsolationHarness: SyntheticServiceHarness
        ownershipIsolationHarness = SyntheticServiceHarness(
            onReadPolicy = {
                if (injectNewerTransientOwner) {
                    controller.installTransientOwnershipForTestOnServiceThread(epoch = 99L, signal = newerOwnerSignal)
                    throw IllegalStateException("injected failure after newer owner installed")
                }
                committedPolicy
            },
            onWait = { ms ->
                nowMs += ms
                if (ms == 1_000L) {
                    failingResetSignal = controller.activeDelaySignalOnServiceThread()
                    injectNewerTransientOwner = true
                }
            },
        )
        val outIsolated = ownershipIsolationHarness.controller.executeReset()
        assertEquals(WebFilterConnectionReset.TransitionOutcome.RESTORE_FAILED_CLOSED, outIsolated)
        assertTrue("failing reset's own signal must be completed", failingResetSignal != null && failingResetSignal!!.isCompleted)
        assertFalse("newer owner's signal must NOT be completed by failing reset", newerOwnerSignal.isCompleted)
        assertEquals("newer owner's signal must remain active", newerOwnerSignal, ownershipIsolationHarness.controller.activeDelaySignalOnServiceThread())
        assertEquals("newer owner's transient epoch must remain intact", 99L, ownershipIsolationHarness.controller.activeTransientEpochOnServiceThread())
        assertEquals("newer authority epoch must be preserved", 99L, ownershipIsolationHarness.controller.currentAuthorityEpochOnServiceThread())
        assertEquals("newer owner's active tunnel must not be closed by failing reset", FilterVpnService.MODE_SINKHOLE_ALL, ownershipIsolationHarness.activeMode)
        assertTrue("no terminal loss while newer transient owner holds tunnel", ownershipIsolationHarness.terminalLossOutcomes.isEmpty())
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
