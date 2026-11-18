package com.familyshield.agent.vpn

/**
 * #830 gating (Fable B1, Claude's conditions): whether a resolved name becomes a report row.
 *
 * Two independent switches gate an unblocked name — the server flag (which the agent learns through the
 * rule set) and this row's own blocked state. A blocked attempt is the parent's rule reporting itself,
 * not browsing history, so it is not behind the switch. The decision lives here as a pure function so
 * the unit test can prove the off state without a tunnel.
 *
 * The exclusion list mirrors `EXCLUDED_SITE_HOSTS` on the server (`services/api/src/lib/siteNames.ts`):
 * the phone drops these before they reach the batch, and the server drops them again if a client does
 * not. Two copies is deliberate — the phone cannot import a TypeScript constant, and the test pins both.
 */
object SiteVisitGate {
    /** Our API and its subdomains, the search-enforcement hosts, and the OS connectivity checks. */
    private val EXCLUDED_HOSTS = setOf(
        "osratech.com",
        "api.osratech.com",
        "staging.osratech.com",
        "forcesafesearch.google.com",
        "strict.bing.com",
        "safe.duckduckgo.com",
        "restrict.youtube.com",
        "restrictmoderate.youtube.com",
        "connectivitycheck.gstatic.com",
        "connectivitycheck.android.com",
        "clients3.google.com",
        "time.android.com",
        "time.google.com",
        "android.clients.google.com",
    )

    /**
     * Fable's #841 blocker A: while the flag is off **no name is uploaded, blocked or not**. The blocked
     * attempt still reaches the parent as a hostless count through its alert; the activity stream carries
     * no site name at all, which is what the policy sentence says.
     */
    fun shouldUpload(siteNamesEnabled: Boolean, blocked: Boolean, excludedHost: Boolean = false): Boolean {
        if (excludedHost) return false
        // `blocked` no longer bypasses the switch; the parameter stays so call sites and rows read the
        // same, and the row that used to assert the bypass now asserts its absence.
        return siteNamesEnabled
    }

    /** True for a listed host, any subdomain of our own domain, and an empty name. */
    fun isExcludedHost(host: String): Boolean {
        // Same normalisation as DnsFilterPolicy.normalize, so a DNS name with its trailing dot matches.
        val h = host.trim().trimEnd('.').lowercase().removePrefix("*.").trimStart('.')
        if (h.isEmpty()) return true
        if (h in EXCLUDED_HOSTS) return true
        return h == "osratech.com" || h.endsWith(".osratech.com")
    }
}
