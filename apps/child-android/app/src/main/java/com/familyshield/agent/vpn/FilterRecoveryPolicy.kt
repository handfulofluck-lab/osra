package com.familyshield.agent.vpn

/**
 * Pure policy for web-filter liveness and recovery after an app update (#934).
 *
 * `osra_vpn_state.established` is persisted in SharedPreferences, so when Android terminates the
 * process during an update (`adb install -r` or Play Store update) without running `onDestroy`,
 * that flag stays `true` even though `FilterVpnService` is dead. Combining it with the in-process
 * [FilterVpnService.tunnelMode] ensures no UI row, capability report, or VPN-bypass check can claim
 * the tunnel is established when this process does not hold an active descriptor.
 */
object FilterRecoveryPolicy {

    /** True only when both the persisted latch and the live in-process tunnel descriptor agree. */
    fun isTunnelEstablished(persistedEstablished: Boolean, liveTunnelMode: String?): Boolean =
        persistedEstablished && liveTunnelMode != null

    /**
     * Whether [com.familyshield.agent.receivers.PackageReplacedReceiver] should restart
     * [FilterVpnService] after a genuine self-replace.
     *
     * Respects pairing, prior VPN consent ([vpnEnabled] + [vpnPrepared]), ADR-0008 consent
     * withdrawal ([consentPaused]), and explicit revocation ([filterLost]). Never silently
     * resurrects a revoked filter or restarts an already-live tunnel.
     */
    fun shouldRestartAfterUpdate(
        isPaired: Boolean,
        vpnEnabled: Boolean,
        vpnPrepared: Boolean,
        consentPaused: Boolean,
        filterLost: Boolean,
        liveTunnelMode: String?,
    ): Boolean = isPaired && vpnEnabled && vpnPrepared && !consentPaused && !filterLost && liveTunnelMode == null

    /**
     * Whether opening the paired status screen should kick off a one-shot background reconnect when
     * the web filter is enabled and prepared but the tunnel is currently down (for example after an
     * update whose background start was deferred by the OS). Never overrides an explicit revoke
     * ([filterLost]) or withdrawn consent ([consentPaused]).
     */
    fun shouldAutoReconnectOnStatusOpen(
        vpnEnabled: Boolean,
        vpnPrepared: Boolean,
        consentPaused: Boolean,
        filterLost: Boolean,
        liveTunnelMode: String?,
    ): Boolean = vpnEnabled && vpnPrepared && !consentPaused && !filterLost && liveTunnelMode == null
}
