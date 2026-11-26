package com.familyshield.agent.vpn

import android.content.Context
import com.familyshield.agent.data.ConsentState
import com.familyshield.agent.data.RuleRepository
import com.familyshield.agent.enforcement.LockState
import com.familyshield.agent.network.dto.WebFilterRuleDto
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext

object WebFilterConnectionReset {
    const val DEFAULT_PAUSE_MS: Long = 1_000L
    const val DEFAULT_RESTORE_RETRIES: Int = 3
    const val DEFAULT_RETRY_BACKOFF_MS: Long = 250L

    enum class TransitionOutcome {
        COMPLETED,
        SUPERSEDED_BY_PAUSE,
        CLEANED_UP_ON_CONSENT_CHANGE,
        EXPIRED_INSTANCE,
        SKIPPED,
        FAILED_ENTRY_RECOVERED,
        FAILED_ENTRY_CLOSED,
        RESTORE_FAILED_CLOSED,
        STOPPED;

        val acknowledged: Boolean
            get() = this == COMPLETED || this == SUPERSEDED_BY_PAUSE
    }

    data class PolicySnapshot(
        val dnsConfig: DnsFilterPolicy.Config = DnsFilterPolicy.Config(),
        val alwaysAllowedApps: List<String> = emptyList(),
        val webFilter: WebFilterRuleDto? = null,
    )

    fun interface ServiceDispatcher {
        suspend fun dispatch(block: () -> Unit)
    }

    class TransientTunnelController(
        private val serviceInstanceId: () -> Long = { 1L },
        private val serviceDispatcher: ServiceDispatcher,
        private val prepareCommittedPolicy: suspend () -> Unit = {},
        private val readCommittedPolicyOnServiceThread: () -> PolicySnapshot = { PolicySnapshot() },
        private val applyPolicyOnServiceThread: (PolicySnapshot) -> Unit = {},
        private val activeModeOnServiceThread: () -> String?,
        private val openModeOnServiceThread: (String, PolicySnapshot) -> Boolean,
        private val closeTunnelOnServiceThread: () -> Unit,
        private val isInternetPausedOnServiceThread: () -> Boolean,
        private val isConsentPausedOnServiceThread: () -> Boolean,
        private val isLockActiveOnServiceThread: () -> Boolean,
        private val waitMs: suspend (Long) -> Unit = { delay(it) },
        private val pauseMs: Long = DEFAULT_PAUSE_MS,
        private val restoreRetries: Int = DEFAULT_RESTORE_RETRIES,
        private val retryBackoffMs: Long = DEFAULT_RETRY_BACKOFF_MS,
    ) {
        private val mutex = Mutex()
        private var authorizedMode: String = FilterVpnService.MODE_DNS
        private var stopping: Boolean = false
        private var tunnelEpoch: Long = 0L
        private var transientTunnelEpoch: Long? = null
        private var lastAppliedBypassApps: List<String> = emptyList()
        private val consentCleanedEpochs = HashSet<Long>()
        @Volatile private var currentDelaySignal: CompletableDeferred<Unit>? = null

        private suspend fun <T> runOnService(block: () -> T): T {
            var out: Any? = null
            var err: Throwable? = null
            serviceDispatcher.dispatch {
                try {
                    out = block()
                } catch (t: Throwable) {
                    err = t
                }
            }
            err?.let { throw it }
            @Suppress("UNCHECKED_CAST")
            return out as T
        }

        fun isStoppingOnServiceThread(): Boolean = stopping

        fun interruptTransientHold() {
            currentDelaySignal?.complete(Unit)
        }

        fun handleAuthoritativeStartOnServiceThread(wantedMode: String): Boolean {
            stopping = false
            authorizedMode = wantedMode
            tunnelEpoch += 1L
            transientTunnelEpoch = null
            currentDelaySignal?.complete(Unit)
            val policy = readCommittedPolicyOnServiceThread()
            applyPolicyOnServiceThread(policy)
            val currentActive = activeModeOnServiceThread()
            if (currentActive != wantedMode || lastAppliedBypassApps != policy.alwaysAllowedApps) {
                val ok = runCatching { openModeOnServiceThread(wantedMode, policy) }.getOrDefault(false)
                if (ok) lastAppliedBypassApps = policy.alwaysAllowedApps
                return ok && activeModeOnServiceThread() == wantedMode
            }
            return true
        }

        fun handleConsentChangedOnServiceThread(consentPausedNow: Boolean) {
            if (!consentPausedNow || stopping) return
            val activeTransient = transientTunnelEpoch ?: return
            consentCleanedEpochs.add(activeTransient)
            currentDelaySignal?.complete(Unit)
            val policy = readCommittedPolicyOnServiceThread()
            applyPolicyOnServiceThread(policy)
            if (!isInternetPausedOnServiceThread() && authorizedMode == FilterVpnService.MODE_DNS) {
                tunnelEpoch += 1L
                val ok = runCatching { openModeOnServiceThread(FilterVpnService.MODE_DNS, policy) }.getOrDefault(false)
                if (ok && activeModeOnServiceThread() == FilterVpnService.MODE_DNS) {
                    lastAppliedBypassApps = policy.alwaysAllowedApps
                    transientTunnelEpoch = null
                } else {
                    runCatching { closeTunnelOnServiceThread() }
                    transientTunnelEpoch = activeTransient
                }
            }
        }

        fun handleServiceStopOnServiceThread() {
            stopping = true
            tunnelEpoch += 1L
            transientTunnelEpoch = null
            currentDelaySignal?.complete(Unit)
            runCatching { closeTunnelOnServiceThread() }
        }

        suspend fun executeReset(requestInstanceId: Long = serviceInstanceId()): TransitionOutcome {
            if (requestInstanceId <= 0L || requestInstanceId != serviceInstanceId()) {
                return TransitionOutcome.EXPIRED_INSTANCE
            }
            return mutex.withLock {
                executeResetLocked(requestInstanceId = requestInstanceId, allowFollowUp = true)
            }
        }

        private sealed interface EntryDecision {
            data class Immediate(val outcome: TransitionOutcome) : EntryDecision
            data class FailedEntry(val hopEpoch: Long) : EntryDecision
            data class Entered(
                val hopEpoch: Long,
                val preHopPolicy: PolicySnapshot,
                val signal: CompletableDeferred<Unit>,
            ) : EntryDecision
        }

        private sealed interface RestoreStep {
            data class Done(val outcome: TransitionOutcome, val appliedPolicy: PolicySnapshot) : RestoreStep
            data object Retry : RestoreStep
        }

        private suspend fun executeResetLocked(
            requestInstanceId: Long,
            allowFollowUp: Boolean,
        ): TransitionOutcome {
            runCatching { prepareCommittedPolicy() }
            val entry = runOnService {
                if (requestInstanceId <= 0L || requestInstanceId != serviceInstanceId()) {
                    return@runOnService EntryDecision.Immediate(TransitionOutcome.EXPIRED_INSTANCE)
                }
                if (stopping ||
                    isConsentPausedOnServiceThread() ||
                    isInternetPausedOnServiceThread() ||
                    isLockActiveOnServiceThread() ||
                    authorizedMode != FilterVpnService.MODE_DNS ||
                    activeModeOnServiceThread() != FilterVpnService.MODE_DNS
                ) {
                    return@runOnService EntryDecision.Immediate(TransitionOutcome.SKIPPED)
                }
                val prePolicy = readCommittedPolicyOnServiceThread()
                applyPolicyOnServiceThread(prePolicy)
                val hopEpoch = ++tunnelEpoch
                transientTunnelEpoch = hopEpoch
                val ok = runCatching {
                    openModeOnServiceThread(FilterVpnService.MODE_SINKHOLE_ALL, prePolicy)
                }.getOrDefault(false) && activeModeOnServiceThread() == FilterVpnService.MODE_SINKHOLE_ALL
                if (!ok) return@runOnService EntryDecision.FailedEntry(hopEpoch)
                lastAppliedBypassApps = prePolicy.alwaysAllowedApps
                val sig = CompletableDeferred<Unit>()
                currentDelaySignal = sig
                if (stopping ||
                    isConsentPausedOnServiceThread() ||
                    isInternetPausedOnServiceThread() ||
                    authorizedMode != FilterVpnService.MODE_DNS ||
                    transientTunnelEpoch != hopEpoch
                ) {
                    sig.complete(Unit)
                }
                EntryDecision.Entered(hopEpoch = hopEpoch, preHopPolicy = prePolicy, signal = sig)
            }

            when (entry) {
                is EntryDecision.Immediate -> return entry.outcome
                is EntryDecision.FailedEntry -> return withContext(NonCancellable) { recoverAfterFailedEntry(entry.hopEpoch) }
                is EntryDecision.Entered -> {
                    var resolved: Pair<TransitionOutcome, PolicySnapshot?>? = null
                    try {
                        awaitWindowOrInterrupt(entry.signal, pauseMs)
                        resolved = withContext(NonCancellable) { restoreAfterWindow(entry.hopEpoch) }
                    } finally {
                        currentDelaySignal = null
                        if (resolved == null) {
                            resolved = withContext(NonCancellable) { restoreAfterWindow(entry.hopEpoch) }
                        }
                        runOnService { consentCleanedEpochs.remove(entry.hopEpoch) }
                    }
                    val (outcome, restoredPolicy) = resolved
                    if (outcome == TransitionOutcome.COMPLETED) {
                        runCatching { prepareCommittedPolicy() }
                        val needFollowUp = runOnService {
                            if (stopping || requestInstanceId != serviceInstanceId()) return@runOnService false
                            val finalPolicy = readCommittedPolicyOnServiceThread()
                            applyPolicyOnServiceThread(finalPolicy)
                            val target = expectedAuthoritativeModeOnServiceThread()
                            if (activeModeOnServiceThread() == target &&
                                lastAppliedBypassApps != finalPolicy.alwaysAllowedApps
                            ) {
                                if (runCatching { openModeOnServiceThread(target, finalPolicy) }.getOrDefault(false)) {
                                    lastAppliedBypassApps = finalPolicy.alwaysAllowedApps
                                }
                            }
                            allowFollowUp &&
                                restoredPolicy != null &&
                                hasNewEffectivePolicyBlock(restoredPolicy, finalPolicy) &&
                                !isConsentPausedOnServiceThread() &&
                                !isInternetPausedOnServiceThread() &&
                                !isLockActiveOnServiceThread() &&
                                authorizedMode == FilterVpnService.MODE_DNS &&
                                activeModeOnServiceThread() == FilterVpnService.MODE_DNS
                        }
                        if (needFollowUp) {
                            return executeResetLocked(requestInstanceId = requestInstanceId, allowFollowUp = false)
                        }
                    }
                    return outcome
                }
            }
        }

        private fun expectedAuthoritativeModeOnServiceThread(): String =
            if (isInternetPausedOnServiceThread() || authorizedMode == FilterVpnService.MODE_SINKHOLE_ALL) {
                FilterVpnService.MODE_SINKHOLE_ALL
            } else {
                FilterVpnService.MODE_DNS
            }

        private suspend fun awaitWindowOrInterrupt(signal: CompletableDeferred<Unit>, durationMs: Long) {
            if (signal.isCompleted) return
            coroutineScope {
                val timer = launch { waitMs(durationMs) }
                val watcher = launch {
                    signal.await()
                    timer.cancel()
                }
                timer.join()
                watcher.cancel()
            }
        }

        private suspend fun recoverAfterFailedEntry(hopEpoch: Long): TransitionOutcome {
            for (attempt in 0 until restoreRetries) {
                if (attempt > 0) runCatching { waitMs(retryBackoffMs) }
                runCatching { prepareCommittedPolicy() }
                val step = runOnService {
                    if (stopping) {
                        if (transientTunnelEpoch == hopEpoch) {
                            runCatching { closeTunnelOnServiceThread() }
                            transientTunnelEpoch = null
                        }
                        return@runOnService RestoreStep.Done(TransitionOutcome.STOPPED, PolicySnapshot())
                    }
                    val policy = readCommittedPolicyOnServiceThread()
                    applyPolicyOnServiceThread(policy)
                    val target = expectedAuthoritativeModeOnServiceThread()
                    if (transientTunnelEpoch != hopEpoch &&
                        activeModeOnServiceThread() == target &&
                        lastAppliedBypassApps == policy.alwaysAllowedApps
                    ) {
                        val out = if (target == FilterVpnService.MODE_SINKHOLE_ALL) {
                            TransitionOutcome.SUPERSEDED_BY_PAUSE
                        } else {
                            TransitionOutcome.FAILED_ENTRY_RECOVERED
                        }
                        return@runOnService RestoreStep.Done(out, policy)
                    }
                    val ok = runCatching { openModeOnServiceThread(target, policy) }.getOrDefault(false) &&
                        activeModeOnServiceThread() == target
                    if (ok) {
                        lastAppliedBypassApps = policy.alwaysAllowedApps
                        if (transientTunnelEpoch == hopEpoch) transientTunnelEpoch = null
                        val out = if (target == FilterVpnService.MODE_SINKHOLE_ALL) {
                            TransitionOutcome.SUPERSEDED_BY_PAUSE
                        } else {
                            TransitionOutcome.FAILED_ENTRY_RECOVERED
                        }
                        RestoreStep.Done(out, policy)
                    } else {
                        RestoreStep.Retry
                    }
                }
                if (step is RestoreStep.Done) return step.outcome
            }
            runOnService {
                if (transientTunnelEpoch == hopEpoch) {
                    runCatching { closeTunnelOnServiceThread() }
                    transientTunnelEpoch = null
                }
            }
            return TransitionOutcome.FAILED_ENTRY_CLOSED
        }

        private suspend fun restoreAfterWindow(hopEpoch: Long): Pair<TransitionOutcome, PolicySnapshot?> {
            for (attempt in 0 until restoreRetries) {
                if (attempt > 0) runCatching { waitMs(retryBackoffMs) }
                runCatching { prepareCommittedPolicy() }
                val step = runOnService {
                    if (stopping) {
                        if (transientTunnelEpoch == hopEpoch) {
                            runCatching { closeTunnelOnServiceThread() }
                            transientTunnelEpoch = null
                        }
                        return@runOnService RestoreStep.Done(TransitionOutcome.STOPPED, PolicySnapshot())
                    }
                    val policy = readCommittedPolicyOnServiceThread()
                    applyPolicyOnServiceThread(policy)
                    val target = expectedAuthoritativeModeOnServiceThread()
                    val consentTriggered = isConsentPausedOnServiceThread() || consentCleanedEpochs.contains(hopEpoch)
                    if (target == FilterVpnService.MODE_SINKHOLE_ALL) {
                        if (activeModeOnServiceThread() == FilterVpnService.MODE_SINKHOLE_ALL &&
                            lastAppliedBypassApps == policy.alwaysAllowedApps
                        ) {
                            if (transientTunnelEpoch == hopEpoch) transientTunnelEpoch = null
                            return@runOnService RestoreStep.Done(TransitionOutcome.SUPERSEDED_BY_PAUSE, policy)
                        }
                        val ok = runCatching {
                            openModeOnServiceThread(FilterVpnService.MODE_SINKHOLE_ALL, policy)
                        }.getOrDefault(false) && activeModeOnServiceThread() == FilterVpnService.MODE_SINKHOLE_ALL
                        return@runOnService if (ok) {
                            lastAppliedBypassApps = policy.alwaysAllowedApps
                            if (transientTunnelEpoch == hopEpoch) transientTunnelEpoch = null
                            RestoreStep.Done(TransitionOutcome.SUPERSEDED_BY_PAUSE, policy)
                        } else {
                            RestoreStep.Retry
                        }
                    }
                    if (transientTunnelEpoch != hopEpoch &&
                        activeModeOnServiceThread() == FilterVpnService.MODE_DNS &&
                        lastAppliedBypassApps == policy.alwaysAllowedApps
                    ) {
                        val out = if (consentTriggered) TransitionOutcome.CLEANED_UP_ON_CONSENT_CHANGE else TransitionOutcome.COMPLETED
                        return@runOnService RestoreStep.Done(out, policy)
                    }
                    val ok = runCatching {
                        openModeOnServiceThread(FilterVpnService.MODE_DNS, policy)
                    }.getOrDefault(false) && activeModeOnServiceThread() == FilterVpnService.MODE_DNS
                    if (ok) {
                        lastAppliedBypassApps = policy.alwaysAllowedApps
                        if (transientTunnelEpoch == hopEpoch) transientTunnelEpoch = null
                        val out = if (consentTriggered) TransitionOutcome.CLEANED_UP_ON_CONSENT_CHANGE else TransitionOutcome.COMPLETED
                        RestoreStep.Done(out, policy)
                    } else {
                        RestoreStep.Retry
                    }
                }
                if (step is RestoreStep.Done) return step.outcome to step.appliedPolicy
            }
            runOnService {
                if (transientTunnelEpoch == hopEpoch) {
                    runCatching { closeTunnelOnServiceThread() }
                    transientTunnelEpoch = null
                }
            }
            return TransitionOutcome.RESTORE_FAILED_CLOSED to null
        }
    }

    fun hasNewEffectivePolicyBlock(before: PolicySnapshot, after: PolicySnapshot): Boolean {
        if (hasNewWebBlock(before.webFilter, after.webFilter)) return true
        if (!before.dnsConfig.safeSearch && after.dnsConfig.safeSearch) return true
        if (youtubeRestrictionRank(after.dnsConfig.youtubeMode) > youtubeRestrictionRank(before.dnsConfig.youtubeMode)) return true
        val beforeManual = effectiveDomainsFromConfig(before.dnsConfig)
        val afterManual = effectiveDomainsFromConfig(after.dnsConfig)
        if ((afterManual - beforeManual).isNotEmpty()) return true
        val beforeCats = before.dnsConfig.blockedCategories.map { it.trim().lowercase() }.filter { it.isNotEmpty() }.toSet()
        val afterCats = after.dnsConfig.blockedCategories.map { it.trim().lowercase() }.filter { it.isNotEmpty() }.toSet()
        return (afterCats - beforeCats).isNotEmpty()
    }

    private fun youtubeRestrictionRank(mode: String): Int = when (mode.trim().lowercase()) {
        "strict" -> 2
        "moderate" -> 1
        else -> 0
    }

    private fun effectiveDomainsFromConfig(cfg: DnsFilterPolicy.Config): Set<String> {
        val allowed = cfg.allowedDomains.map(DnsFilterPolicy::normalize).filter { it.isNotEmpty() }
        return cfg.blockedDomains
            .map(DnsFilterPolicy::normalize)
            .filter { domain -> domain.isNotEmpty() && allowed.none { allow -> DnsFilterPolicy.matches(domain, allow) } }
            .toSet()
    }

    fun hasNewWebBlock(before: WebFilterRuleDto?, after: WebFilterRuleDto?): Boolean {
        if (after == null) return false
        if ((effectiveBlockedDomains(after) - effectiveBlockedDomains(before)).isNotEmpty()) return true
        return (normalizedCategories(after) - normalizedCategories(before)).isNotEmpty()
    }

    fun shouldResetConnections(before: WebFilterRuleDto?, after: WebFilterRuleDto?): Boolean =
        hasNewWebBlock(before, after)

    suspend fun resetIfNeeded(
        context: Context,
        rules: RuleRepository,
        consent: ConsentState,
        before: WebFilterRuleDto?,
        after: WebFilterRuleDto?,
    ): Boolean {
        if (!shouldResetConnections(before, after)) return false
        return resetOpenConnections(context, rules, consent)
    }

    suspend fun resetOpenConnections(
        context: Context,
        rules: RuleRepository,
        consent: ConsentState,
    ): Boolean {
        if (consent.isPaused() || rules.isInternetPaused() || LockState.isActive(context)) return false
        return FilterVpnService.awaitConnectionReset(context).acknowledged
    }

    private fun effectiveBlockedDomains(wf: WebFilterRuleDto?): Set<String> {
        if (wf == null) return emptySet()
        val allowed = wf.allowedDomains.map(DnsFilterPolicy::normalize).filter { it.isNotEmpty() }
        return wf.blockedDomains
            .map(DnsFilterPolicy::normalize)
            .filter { domain -> domain.isNotEmpty() && allowed.none { allow -> DnsFilterPolicy.matches(domain, allow) } }
            .toSet()
    }

    private fun normalizedCategories(wf: WebFilterRuleDto?): Set<String> =
        wf?.blockedCategories.orEmpty().map { it.trim().lowercase() }.filter { it.isNotEmpty() }.toSet()
}
