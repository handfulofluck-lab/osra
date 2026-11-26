package com.familyshield.agent.vpn

/**
 * Pure decision table for the local DNS sinkhole (plan item 1.4, ADR-0015). Given the family's web
 * filter and the device state, says what the resolver does with one query name. No Android types,
 * so the whole table is unit-tested on the JVM; [FilterVpnService] only moves packets.
 *
 * Precedence, highest first:
 *  1. pause-internet → every name is sunk (the VPN also sinks non-DNS traffic in that mode);
 *  2. an explicit allowed domain (or a subdomain of one) → forwarded untouched, whatever else says;
 *  3. an explicit blocked domain, or a domain in a blocked category → sunk. A parent's block must
 *     beat a rewrite: rewriting a blocked `youtube.com` to `restrict.youtube.com` would leave the site
 *     reachable, which is #825 on the Flip4;
 *  4. SafeSearch / YouTube Restricted → the engine's own enforcement host (a CNAME-style rewrite
 *     the vendors document for exactly this purpose: `forcesafesearch.google.com`,
 *     `strict.bing.com`, `safe.duckduckgo.com`, `restrict.youtube.com`);
 *  5. otherwise forwarded to the upstream resolver.
 *
 * Matching is by DNS label suffix: `blocked.example` covers `www.blocked.example` but not
 * `notblocked.example`. Names are compared lower-case with the trailing dot removed.
 */
object DnsFilterPolicy {

    enum class Action { FORWARD, SINK, REWRITE }

    /**
     * Issue #1079: what the filter can honestly promise. Kept separate from [decide] because the decision
     * for one name is not a claim about the filter: a policy that forwards everything looks identical to a
     * policy that blocks nothing, and the parent cannot tell the two apart from the outside.
     */
    enum class EnforcementState {
        /** The family blocks no category, so an empty pack is the correct state, not a fault. */
        NOT_APPLICABLE,

        /** Categories are blocked and the pack that enforces them is on the device. */
        ENFORCING,

        /** Categories are blocked and no pack has ever been stored: the filter is up and enforces nothing. */
        UNPROTECTED,
    }

    /**
     * The state [#decide]'s caller should report. Pure, so the three cases are JVM rows.
     *
     * Reads the **normalised** [Config.categories], not the raw map: a pack entry whose domain is blank or a
     * bare `*.` normalises away, and a table that empties out must not report as enforcing (Hydrogen's #1097
     * review). A category list of blanks is no category at all, not a broken filter.
     */
    fun enforcement(config: Config): EnforcementState = when {
        config.blockedCategories.none { it.trim().isNotEmpty() } -> EnforcementState.NOT_APPLICABLE
        config.packLoaded && config.categories.isNotEmpty() -> EnforcementState.ENFORCING
        else -> EnforcementState.UNPROTECTED
    }

    /**
     * The same question from the three facts a caller on the phone actually holds, so the capability report
     * and the tunnel ask one function instead of keeping two copies of the rule (Hydrogen, #1097 review).
     */
    fun enforcement(
        categoryDomains: Map<String, String>,
        packStored: Boolean,
        blockedCategories: Collection<String>,
    ): EnforcementState = enforcement(
        Config(
            categoryDomains = categoryDomains,
            packLoaded = packStored,
            blockedCategories = blockedCategories,
        ),
    )

    /** [target] is set only for [Action.REWRITE]; [reason] is for the log line and the alert. */
    data class Decision(val action: Action, val target: String? = null, val reason: String = "") {
        companion object {
            val FORWARD = Decision(Action.FORWARD)
        }
    }

    data class Config(
        val pausedInternet: Boolean = false,
        /** #830 gating: the server flag; false keeps unblocked names on the phone. */
        val siteNamesEnabled: Boolean = false,
        val safeSearch: Boolean = false,
        /** "strict" | "moderate" | "off" — anything else is treated as "off". */
        val youtubeMode: String = "off",
        val allowedDomains: Collection<String> = emptyList(),
        val blockedDomains: Collection<String> = emptyList(),
        /** domain → category, the blocklist pack already filtered to the blocked categories. */
        val categoryDomains: Map<String, String> = emptyMap(),
        /**
         * Issue #1079: whether a blocklist pack has ever been stored on this device. Empty domains plus
         * `false` is "the filter is up and enforcing nothing", which is what child 2 looked like; empty
         * domains plus `true` is a family that blocks no category, which is correct.
         */
        val packLoaded: Boolean = true,
        /** The categories the rule set blocks. With none, an empty pack is not a fault. */
        val blockedCategories: Collection<String> = emptyList(),
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
        if (config.allowed.any { matches(name, it) }) return Decision.FORWARD

        // #825: a parent's block beats any rewrite; only an explicit allow outranks it. The enforcement
        // hosts are checked *after* this, so a direct query for restrict.youtube.com under a blocked
        // youtube.com sinks instead of resolving YouTube (Fable, R3 on #825).
        config.blocked.firstOrNull { matches(name, it) }?.let { return Decision(Action.SINK, reason = "blocked_domain:$it") }
        config.categories.entries.firstOrNull { matches(name, it.key) }?.let { return Decision(Action.SINK, reason = "category:${it.value}") }

        // A rewrite never targets another enforcement host, so forwarding these here cannot loop; when
        // nothing blocks them they resolve normally.
        if (name in ENFORCEMENT_HOSTS) return Decision.FORWARD

        if (config.safeSearch) {
            if (isGoogleSearchHost(name)) return Decision(Action.REWRITE, GOOGLE_SAFE, "safesearch")
            if (BING_HOSTS.any { name == it }) return Decision(Action.REWRITE, BING_SAFE, "safesearch")
            if (DDG_HOSTS.any { name == it }) return Decision(Action.REWRITE, DDG_SAFE, "safesearch")
        }
        when (config.youtubeMode.trim().lowercase()) {
            "strict" -> if (YOUTUBE_HOSTS.any { name == it }) return Decision(Action.REWRITE, YT_STRICT, "youtube_strict")
            "moderate" -> if (YOUTUBE_HOSTS.any { name == it }) return Decision(Action.REWRITE, YT_MODERATE, "youtube_moderate")
        }

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

    internal fun normalize(raw: String): String {
        val name = raw.trim().trimEnd('.').lowercase().removePrefix("*.")
        // A bare "*" (or "*." that trimmed to one) is not a domain: it matches no real query, so keeping it
        // made an all-junk pack look like a non-empty — hence enforcing — table (#1079 wiring review).
        return if (name == "*") "" else name
    }
}
