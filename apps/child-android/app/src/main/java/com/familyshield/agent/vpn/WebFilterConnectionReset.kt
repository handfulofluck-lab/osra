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

/**
 * Issue #1224: service-owned transient `MODE_SINKHOLE_ALL -> MODE_DNS` connection reset when a
 * domain or category becomes newly blocked, plus shared policy seam for `#1226`.
 *
 * Reliability invariants:
 * 1. [TransientTunnelController] lives inside [FilterVpnService] under the service's lifetime.
 * 2. The hold timer (`pauseMs`) starts strictly AFTER `openMode(MODE_SINKHOLE_ALL)` establishes
 *    the new tunnel descriptor.
 * 3. Callers (`resetIfNeeded` / `resetOpenConnections`) await [FilterVpnService.awaitConnectionReset],
 *    acknowledging only an actual completed transition rather than intent dispatch.
 * 4. Entry or restore failures recover the authoritative mode (`authorizedMode`) with bounded retries,
 *    closing any leftover transient sinkhole if restoration cannot re-establish `MODE_DNS`.
 * 5. Authoritative `authorizedMode` / `internetPaused` is tracked separately from `consentPaused`:
 *    deliberate Internet Pause keeps `MODE_SINKHOLE_ALL`, whereas consent withdrawal interrupts the
 *    transient hold and restores `MODE_DNS` (or closes the tunnel) so `0.0.0.0/0` sinkhole routing
 *    never stays active under withdrawn consent.
 */
object WebFilterConnectionReset {
    const val DEFAULT_PAUSE_MS: Long = 1_000L
    const val DEFAULT_RESTORE_RETRIES: Int = 3
    const val DEFAULT_RETRY_BACKOFF_MS: Long = 250L

    enum class TransitionOutcome {
        COMPLETED,
        SUPERSEDED_BY_PAUSE,
        CLEANED_UP_ON_CONSENT_CHANGE,
        SKIPPED,
        FAILED_ENTRY_RECOVERED,
        FAILED_ENTRY_CLOSED,
        RESTORE_FAILED_CLOSED,
        STOPPED;

        val acknowledged: Boolean
            get() = this == COMPLETED || this == SUPERSEDED_BY_PAUSE
    }

    data class ServiceSnapshot(
        val authorizedMode: String = FilterVpnService.MODE_DNS,
        val activeMode: String? = FilterVpnService.MODE_DNS,
        val internetPaused: Boolean = false,
        val consentPaused: Boolean = false,
        val lockActive: Boolean = false,
        val stopping: Boolean = false,
    )

    class TransientTunnelController(
        private val readSnapshot: () -> ServiceSnapshot,
        private val openMode: suspend (String) -> Boolean,
        private val closeTunnel: suspend () -> Unit,
        private val waitMs: suspend (Long) -> Unit = { delay(it) },
        private val pauseMs: Long = DEFAULT_PAUSE_MS,
        private val restoreRetries: Int = DEFAULT_RESTORE_RETRIES,
        private val retryBackoffMs: Long = DEFAULT_RETRY_BACKOFF_MS,
    ) {
        private val mutex = Mutex()
        @Volatile private var currentDelaySignal: CompletableDeferred<Unit>? = null

        /** Wakes an in-flight transient hold immediately on stop, pause_internet, or consent change. */
        fun interruptTransientHold() {
            currentDelaySignal?.complete(Unit)
        }

        suspend fun executeReset(): TransitionOutcome = mutex.withLock {
            val initial = readSnapshot()
            if (initial.stopping ||
                initial.consentPaused ||
                initial.internetPaused ||
                initial.lockActive ||
                initial.authorizedMode != FilterVpnService.MODE_DNS ||
                initial.activeMode != FilterVpnService.MODE_DNS
            ) {
                return@withLock TransitionOutcome.SKIPPED
            }

            val entered = runCatching { openMode(FilterVpnService.MODE_SINKHOLE_ALL) }.getOrDefault(false)
            if (!entered) {
                return@withLock withContext(NonCancellable) {
                    recoverAfterFailedEntry()
                }
            }

            val signal = CompletableDeferred<Unit>()
            currentDelaySignal = signal
            val postEstablish = readSnapshot()
            if (postEstablish.stopping ||
                postEstablish.consentPaused ||
                postEstablish.internetPaused ||
                postEstablish.authorizedMode != FilterVpnService.MODE_DNS
            ) {
                signal.complete(Unit)
            }

            var resolvedOutcome: TransitionOutcome? = null
            try {
                awaitWindowOrInterrupt(signal, pauseMs)
                resolvedOutcome = withContext(NonCancellable) {
                    restoreAfterWindow()
                }
                return@withLock resolvedOutcome
            } finally {
                currentDelaySignal = null
                if (resolvedOutcome == null) {
                    withContext(NonCancellable) {
                        restoreAfterWindow()
                    }
                }
            }
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

        private suspend fun recoverAfterFailedEntry(): TransitionOutcome {
            for (attempt in 0 until restoreRetries) {
                val snap = readSnapshot()
                if (snap.stopping) {
                    runCatching { closeTunnel() }
                    return TransitionOutcome.STOPPED
                }
                if (attempt > 0) {
                    runCatching { waitMs(retryBackoffMs) }
                    if (readSnapshot().stopping) {
                        runCatching { closeTunnel() }
                        return TransitionOutcome.STOPPED
                    }
                }
                val latest = readSnapshot()
                val target = if (latest.internetPaused || latest.authorizedMode == FilterVpnService.MODE_SINKHOLE_ALL) {
                    FilterVpnService.MODE_SINKHOLE_ALL
                } else {
                    FilterVpnService.MODE_DNS
                }
                if (runCatching { openMode(target) }.getOrDefault(false)) {
                    return TransitionOutcome.FAILED_ENTRY_RECOVERED
                }
            }
            runCatching { closeTunnel() }
            return TransitionOutcome.FAILED_ENTRY_CLOSED
        }

        private suspend fun restoreAfterWindow(): TransitionOutcome {
            val initialSnap = readSnapshot()
            if (initialSnap.stopping) {
                runCatching { closeTunnel() }
                return TransitionOutcome.STOPPED
            }
            if (initialSnap.internetPaused || initialSnap.authorizedMode == FilterVpnService.MODE_SINKHOLE_ALL) {
                if (initialSnap.activeMode != FilterVpnService.MODE_SINKHOLE_ALL) {
                    runCatching { openMode(FilterVpnService.MODE_SINKHOLE_ALL) }
                }
                return TransitionOutcome.SUPERSEDED_BY_PAUSE
            }

            val consentChangedAtStart = initialSnap.consentPaused
            for (attempt in 0 until restoreRetries) {
                if (attempt > 0) {
                    runCatching { waitMs(retryBackoffMs) }
                }
                val snap = readSnapshot()
                if (snap.stopping) {
                    runCatching { closeTunnel() }
                    return TransitionOutcome.STOPPED
                }
                if (snap.internetPaused || snap.authorizedMode == FilterVpnService.MODE_SINKHOLE_ALL) {
                    if (snap.activeMode != FilterVpnService.MODE_SINKHOLE_ALL) {
                        runCatching { openMode(FilterVpnService.MODE_SINKHOLE_ALL) }
                    }
                    return TransitionOutcome.SUPERSEDED_BY_PAUSE
                }
                if (runCatching { openMode(FilterVpnService.MODE_DNS) }.getOrDefault(false)) {
                    return if (consentChangedAtStart || readSnapshot().consentPaused) {
                        TransitionOutcome.CLEANED_UP_ON_CONSENT_CHANGE
                    } else {
                        TransitionOutcome.COMPLETED
                    }
                }
            }

            // Never leave transient MODE_SINKHOLE_ALL active when MODE_DNS could not be restored.
            runCatching { closeTunnel() }
            return TransitionOutcome.RESTORE_FAILED_CLOSED
        }
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