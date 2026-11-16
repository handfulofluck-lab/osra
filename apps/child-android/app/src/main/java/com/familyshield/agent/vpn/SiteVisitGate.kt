package com.familyshield.agent.vpn

/**
 * #830 gating (Fable B1, Claude's conditions): whether a resolved name becomes a report row.
 *
 * Two independent switches gate an unblocked name — the server flag (which the agent learns through the
 * rule set) and this row's own blocked state. A blocked attempt is the parent's rule reporting itself,
 * not browsing history, so it is not behind the switch. The decision lives here as a pure function so
 * the unit test can prove the off state without a tunnel.
 */
object SiteVisitGate {
    fun shouldUpload(siteNamesEnabled: Boolean, blocked: Boolean, excludedHost: Boolean = false): Boolean {
        if (excludedHost) return false
        return blocked || siteNamesEnabled
    }
}
