package com.familyshield.agent.vpn

import android.content.Context
import com.familyshield.agent.data.ConsentState
import com.familyshield.agent.data.RuleRepository
import com.familyshield.agent.enforcement.LockState
import com.familyshield.agent.network.dto.WebFilterRuleDto
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.delay
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext

/**
 * Issue #1224: brief (~1 s) transient `MODE_SINKHOLE_ALL -> MODE_DNS` switch on an already-running
 * DNS filter when a domain or category becomes newly blocked, cutting open TCP/QUIC browser tabs
 * without touching `LockState`, `LockPeriodTracker`, `LockActivity`, receipts, or persistent
 * [VpnState.mode].
 *
 * Designed as the single shared policy-reset seam so `#1226` (SafeSearch / search-rewrite tightening)
 * can extend [shouldResetConnections] or call [resetOpenConnections] without a second mechanism.
 */
object WebFilterConnectionReset {
    const val DEFAULT_PAUSE_MS: Long = 1_000L
    private val bounceMutex = Mutex()

    data class TunnelState(
        val consentPaused: Boolean = false,
        val vpnEnabled: Boolean = true,
        val vpnPrepared: Boolean = true,
        val serviceRunning: Boolean = true,
        val tunnelMode: String? = FilterVpnService.MODE_DNS,
        val persistentMode: String = FilterVpnService.MODE_DNS,
        val internetPaused: Boolean = false,
        val lockActive: Boolean = false,
    )

    /**
     * True when [after] blocks at least one effective domain or category that [before] did not block.
     * Respects `allowedDomains` precedence (`DnsFilterPolicy.decide`, #825): removing an allow
     * exemption that uncovered an existing blocked domain counts as newly blocked; unblocking a domain
     * or category, adding an allowed domain, or changing only casing/trailing dots returns false.
     */
    fun hasNewWebBlock(before: WebFilterRuleDto?, after: WebFilterRuleDto?): Boolean {
        if (after == null) return false
        if ((effectiveBlockedDomains(after) - effectiveBlockedDomains(before)).isNotEmpty()) return true
        return (normalizedCategories(after) - normalizedCategories(before)).isNotEmpty()
    }

    /**
     * Shared policy-change trigger for `#1224` (and `#1226` SafeSearch tightening).
     */
    fun shouldResetConnections(before: WebFilterRuleDto?, after: WebFilterRuleDto?): Boolean =
        hasNewWebBlock(before, after)

    /**
     * Pre-bounce gate: requires active consent, an established `MODE_DNS` tunnel, persistent mode
     * `MODE_DNS`, and neither `pause_internet` nor any `LockState` active (`locked`, `paused`,
     * `paused_internet`). Never starts a stopped or unconsented VPN (#848).
     */
    fun canStartBounce(state: TunnelState): Boolean =
        !state.consentPaused &&
            state.vpnEnabled &&
            state.vpnPrepared &&
            state.serviceRunning &&
            state.tunnelMode == FilterVpnService.MODE_DNS &&
            state.persistentMode == FilterVpnService.MODE_DNS &&
            !state.internetPaused &&
            !state.lockActive

    /**
     * Post-delay gate: restores `MODE_DNS` unless `pause_internet` took over (`internetPaused` or
     * `persistentMode != MODE_DNS`) or the VPN was stopped / unconsented during the 1 s window.
     * A screen-only `lock` (`lockActive == true`, `internetPaused == false`) still restores `MODE_DNS`
     * so the transient sinkhole never leaks.
     */
    fun canRestoreDns(state: TunnelState): Boolean =
        !state.consentPaused &&
            state.vpnEnabled &&
            state.vpnPrepared &&
            state.serviceRunning &&
            state.persistentMode == FilterVpnService.MODE_DNS &&
            !state.internetPaused

    /**
     * Pure JVM-testable state machine serialized across callers so overlapping updates cannot interleave.
     */
    suspend fun runBounceIfEligible(
        policyTriggered: Boolean,
        readState: () -> TunnelState,
        switchMode: (String) -> Boolean,
        waitMs: suspend (Long) -> Unit = { delay(it) },
        pauseMs: Long = DEFAULT_PAUSE_MS,
    ): Boolean {
        if (!policyTriggered) return false
        return bounceMutex.withLock {
            if (!canStartBounce(readState())) return@withLock false
            if (!switchMode(FilterVpnService.MODE_SINKHOLE_ALL)) return@withLock false
            try {
                waitMs(pauseMs)
            } finally {
                withContext(NonCancellable) {
                    if (canRestoreDns(readState())) {
                        runCatching { switchMode(FilterVpnService.MODE_DNS) }
                    }
                }
            }
            true
        }
    }

    suspend fun resetIfNeeded(
        context: Context,
        rules: RuleRepository,
        consent: ConsentState,
        before: WebFilterRuleDto?,
        after: WebFilterRuleDto?,
        pauseMs: Long = DEFAULT_PAUSE_MS,
    ): Boolean = runBounceIfEligible(
        policyTriggered = shouldResetConnections(before, after),
        readState = { readAndroidTunnelState(context, rules, consent) },
        switchMode = { wanted -> FilterVpnService.switchRunningTunnelMode(context, wanted) },
        pauseMs = pauseMs,
    )

    suspend fun resetOpenConnections(
        context: Context,
        rules: RuleRepository,
        consent: ConsentState,
        pauseMs: Long = DEFAULT_PAUSE_MS,
    ): Boolean = runBounceIfEligible(
        policyTriggered = true,
        readState = { readAndroidTunnelState(context, rules, consent) },
        switchMode = { wanted -> FilterVpnService.switchRunningTunnelMode(context, wanted) },
        pauseMs = pauseMs,
    )

    private fun readAndroidTunnelState(
        context: Context,
        rules: RuleRepository,
        consent: ConsentState,
    ): TunnelState = TunnelState(
        consentPaused = consent.isPaused(),
        vpnEnabled = VpnState.isEnabled(context),
        vpnPrepared = FilterVpnService.isPrepared(context),
        serviceRunning = FilterVpnService.isRunning,
        tunnelMode = FilterVpnService.tunnelMode,
        persistentMode = VpnState.mode(context),
        internetPaused = rules.isInternetPaused(),
        lockActive = LockState.isActive(context),
    )

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