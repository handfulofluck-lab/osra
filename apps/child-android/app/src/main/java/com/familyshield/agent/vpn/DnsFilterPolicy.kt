package com.familyshield.agent.vpn

/**
 * Pure decision table for the local DNS sinkhole (plan item 1.4, ADR-0015). Given the family's web
 * filter and the device state, says what the resolver does with one query name. No Android types,
 * so the whole table is unit-tested on the JVM; [FilterVpnService] only moves packets.
 *
 * Precedence, highest first:
 *  1. pause-internet → every name is sunk (the VPN also sinks non-DNS traffic in that mode);
 *  2. an explicit allowed domain (or a subdomain of one) → forwarded untouched, whatever else says;
 *  3. SafeSearch / YouTube Restricted → the engine's own enforcement host (a CNAME-style rewrite
 *     the vendors document for exactly this purpose: `forcesafesearch.google.com`,
 *     `strict.bing.com`, `safe.duckduckgo.com`, `restrict.youtube.com`);
 *  4. an explicit blocked domain, or a domain in a blocked category → sunk;
 *  5. otherwise forwarded to the upstream resolver.
 *
 * Matching is by DNS label suffix: `blocked.example` covers `www.blocked.example` but not
 * `notblocked.example`. Names are compared lower-case with the trailing dot removed.
 */
object DnsFilterPolicy {

    enum class Action { FORWARD, SINK, REWRITE }

    /** [target] is set only for [Action.REWRITE]; [reason] is for the log line and the alert. */
    data class Decision(val action: Action, val target: String? = null, val reason: String = "") {
        companion object {
            val FORWARD = Decision(Action.FORWARD)
        }
    }

    data class Config(
        val pausedInternet: Boolean = false,
        val safeSearch: Boolean = false,
        /** "strict" | "moderate" | "off" — anything else is treated as "off". */
        val youtubeMode: String = "off",
        val allowedDomains: Collection<String> = emptyList(),
        val blockedDomains: Collection<String> = emptyList(),
        /** domain → category, the blocklist pack already filtered to the blocked categories. */
        val categoryDomains: Map<String, String> = emptyMap(),
    ) {
        internal val allowed: List<String> = allowedDomains.map(::normalize).filter { it.isNotEmpty() }
        internal val blocked: List<String> = blockedDomains.map(::normalize).filter { it.isNotEmpty() }
        internal val categories: Map<String, String> =
            categoryDomains.entries.associate { normalize(it.key) to it.value.trim().lowercase() }.filterKeys { it.isNotEmpty() }
    }

    /** Google search hosts: any `google.<tld>` or `www.google.<tld>`; the enforcement host is one for all of them. */
    private val GOOGLE_SAFE = "forcesafesearch.google.com"
    private val BING_SAFE = "strict.bing.com"
    private val DDG_SAFE = "safe.duckduckgo.com"
    private val YT_STRICT = "restrict.youtube.com"
    private val YT_MODERATE = "restrictmoderate.youtube.com"

    /** Hosts the YouTube restriction host answers for (documented by Google for network admins). */
    private val YOUTUBE_HOSTS = listOf(
        "www.youtube.com", "m.youtube.com", "youtubei.googleapis.com", "youtube.googleapis.com", "www.youtube-nocookie.com",
    )
    private val BING_HOSTS = listOf("www.bing.com", "bing.com")
    private val DDG_HOSTS = listOf("duckduckgo.com", "www.duckduckgo.com", "start.duckduckgo.com")

    /** The enforcement hosts themselves must never be rewritten or sunk, or the rewrite loops. */
    private val ENFORCEMENT_HOSTS = setOf(GOOGLE_SAFE, BING_SAFE, DDG_SAFE, YT_STRICT, YT_MODERATE)

    fun decide(qname: String, config: Config): Decision {
        val name = normalize(qname)
        if (name.isEmpty()) return Decision.FORWARD
        if (config.pausedInternet) return Decision(Action.SINK, reason = "paused_internet")
        if (name in ENFORCEMENT_HOSTS) return Decision.FORWARD
        if (config.allowed.any { matches(name, it) }) return Decision.FORWARD

        if (config.safeSearch) {
            if (isGoogleSearchHost(name)) return Decision(Action.REWRITE, GOOGLE_SAFE, "safesearch")
            if (BING_HOSTS.any { name == it }) return Decision(Action.REWRITE, BING_SAFE, "safesearch")
            if (DDG_HOSTS.any { name == it }) return Decision(Action.REWRITE, DDG_SAFE, "safesearch")
        }
        when (config.youtubeMode.trim().lowercase()) {
            "strict" -> if (YOUTUBE_HOSTS.any { name == it }) return Decision(Action.REWRITE, YT_STRICT, "youtube_strict")
            "moderate" -> if (YOUTUBE_HOSTS.any { name == it }) return Decision(Action.REWRITE, YT_MODERATE, "youtube_moderate")
        }

        config.blocked.firstOrNull { matches(name, it) }?.let { return Decision(Action.SINK, reason = "blocked_domain:$it") }
        config.categories.entries.firstOrNull { matches(name, it.key) }?.let { return Decision(Action.SINK, reason = "category:${it.value}") }
        return Decision.FORWARD
    }

    /** `google.com`, `www.google.co.uk`, `google.ae` … but not `mail.google.com` or `googleapis.com`. */
    internal fun isGoogleSearchHost(name: String): Boolean {
        val host = name.removePrefix("www.")
        if (!host.startsWith("google.")) return false
        val tld = host.removePrefix("google.")
        // one or two labels of 2–3 letters: "com", "ae", "co.uk", "com.au"
        return tld.matches(Regex("^[a-z]{2,3}(\\.[a-z]{2,3})?$"))
    }

    /** DNS-label suffix match: [name] equals [domain] or ends with ".[domain]". */
    internal fun matches(name: String, domain: String): Boolean =
        name == domain || name.endsWith(".$domain")

    internal fun normalize(raw: String): String =
        raw.trim().trimEnd('.').lowercase().removePrefix("*.")
}
