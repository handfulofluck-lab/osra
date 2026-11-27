package com.familyshield.agent.vpn

/**
 * Pure JVM policy for #1051 option (c) ("close that tab only"), gated behind
 * [WebFilterRow20Fallback.isTabCloseEnabled] (default off).
 *
 * Privacy invariant (#1051):
 * - Only the normalized DNS host is extracted on the call stack from the browser's URL-bar view;
 *   scheme, credentials, port, path, query string, and fragment are stripped immediately in memory
 *   and never logged, persisted, or uploaded.
 * - Focused editable omnibox nodes (`isFocusedEditable == true`) are ignored so partial keystrokes
 *   and search queries are never treated as navigated hosts.
 * - Only [DnsFilterPolicy.Action.SINK] (with `pausedInternet == false`) triggers eviction:
 *   SafeSearch and YouTube Restricted Mode (`Action.REWRITE`) and explicit `allowedDomains`
 *   (`Action.FORWARD`) never close tabs.
 */
class BrowserTabBlockPolicy(
    private val debounceMs: Long = DEFAULT_STEP_DEBOUNCE_MS,
    private val maxBackSteps: Int = DEFAULT_MAX_BACK_STEPS,
    private val episodeResetMs: Long = DEFAULT_EPISODE_RESET_MS,
) {
    enum class Step {
        NONE,
        CLOSE_OR_BACK,
        GO_HOME,
    }

    data class Decision(
        val step: Step,
        val pauseBrowserMedia: Boolean = false,
    ) {
        companion object {
            val NONE = Decision(Step.NONE, pauseBrowserMedia = false)
        }
    }

    data class UrlBarObservation(
        val text: String?,
        val isFocusedEditable: Boolean = false,
    )

    private var activeEpisodeKey: String? = null
    private var episodeStepCount: Int = 0
    private var lastStepElapsedMs: Long = 0L
    private var hasSteppedInEpisode: Boolean = false

    fun reset() {
        activeEpisodeKey = null
        episodeStepCount = 0
        lastStepElapsedMs = 0L
        hasSteppedInEpisode = false
    }

    fun evaluate(
        enabled: Boolean,
        paired: Boolean,
        consentPaused: Boolean,
        lockActive: Boolean,
        pausedInternet: Boolean,
        browserPackage: String?,
        observation: UrlBarObservation?,
        dnsConfig: DnsFilterPolicy.Config,
        nowElapsedMs: Long,
    ): Decision {
        if (!enabled || !paired || consentPaused || lockActive || pausedInternet) {
            reset()
            return Decision.NONE
        }
        val pkg = browserPackage?.trim()?.lowercase().orEmpty()
        if (!isKnownBrowser(pkg) || observation == null || observation.isFocusedEditable) {
            if (!isKnownBrowser(pkg)) reset()
            return Decision.NONE
        }
        val host = extractNormalizedHost(observation.text)
        if (host == null) {
            reset()
            return Decision.NONE
        }
        val effectiveConfig = if (dnsConfig.pausedInternet) dnsConfig.copy(pausedInternet = false) else dnsConfig
        val dnsDecision = DnsFilterPolicy.decide(host, effectiveConfig)
        if (dnsDecision.action != DnsFilterPolicy.Action.SINK) {
            reset()
            return Decision.NONE
        }

        val episodeKey = "$pkg|$host"
        val elapsedSinceLast = nowElapsedMs - lastStepElapsedMs
        if (activeEpisodeKey != episodeKey || (hasSteppedInEpisode && elapsedSinceLast >= episodeResetMs)) {
            activeEpisodeKey = episodeKey
            episodeStepCount = 0
            hasSteppedInEpisode = false
        } else if (hasSteppedInEpisode && elapsedSinceLast in 0 until debounceMs) {
            return Decision.NONE
        }

        val nextStep = when {
            episodeStepCount < maxBackSteps -> Step.CLOSE_OR_BACK
            episodeStepCount == maxBackSteps -> Step.GO_HOME
            else -> return Decision.NONE
        }
        episodeStepCount += 1
        lastStepElapsedMs = nowElapsedMs
        hasSteppedInEpisode = true
        return Decision(step = nextStep, pauseBrowserMedia = true)
    }

    companion object {
        const val DEFAULT_STEP_DEBOUNCE_MS: Long = 750L
        const val DEFAULT_MAX_BACK_STEPS: Int = 2
        const val DEFAULT_EPISODE_RESET_MS: Long = 10_000L

        private val BROWSER_URL_BAR_SUFFIXES: Map<String, List<String>> = mapOf(
            "com.android.chrome" to listOf("url_bar"),
            "com.chrome.beta" to listOf("url_bar"),
            "com.chrome.dev" to listOf("url_bar"),
            "com.chrome.canary" to listOf("url_bar"),
            "com.sec.android.app.sbrowser" to listOf("location_bar_edit_text", "url_bar"),
            "com.sec.android.app.sbrowser.beta" to listOf("location_bar_edit_text", "url_bar"),
            "org.mozilla.firefox" to listOf("mozac_browser_toolbar_url_view", "url_bar"),
            "org.mozilla.firefox_beta" to listOf("mozac_browser_toolbar_url_view", "url_bar"),
            "org.mozilla.fenix" to listOf("mozac_browser_toolbar_url_view", "url_bar"),
            "com.microsoft.emmx" to listOf("url_bar", "omnibox_url_field"),
            "com.brave.browser" to listOf("url_bar"),
            "com.opera.browser" to listOf("url_field", "url_bar"),
            "com.opera.mini.native" to listOf("url_field", "url_bar"),
            "com.vivaldi.browser" to listOf("url_bar"),
            "com.duckduckgo.mobile.android" to listOf("omnibarTextInput", "url_bar"),
        )

        private val BIDI_AND_FORMAT_CHARS = Regex("[\\u200B-\\u200F\\u202A-\\u202E\\u2060\\u2066-\\u2069\\uFEFF]")
        private val HOST_LABEL = Regex("^[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?$")
        private val ALL_DIGITS = Regex("^\\d+$")

        fun isKnownBrowser(packageName: String?): Boolean =
            packageName != null && packageName.trim().lowercase() in BROWSER_URL_BAR_SUFFIXES

        fun urlBarViewIdsFor(packageName: String?): List<String> {
            val pkg = packageName?.trim()?.lowercase() ?: return emptyList()
            val suffixes = BROWSER_URL_BAR_SUFFIXES[pkg] ?: return emptyList()
            return suffixes.map { "$pkg:id/$it" }
        }

        /**
         * Extracts only the normalized DNS hostname from a browser address-bar string, discarding
         * scheme, credentials, port, path, query, and fragment immediately in memory. Returns `null`
         * for search phrases, internal `about:`/`chrome:` pages, IP literals, or malformed strings.
         */
        fun extractNormalizedHost(rawText: String?): String? {
            if (rawText.isNullOrBlank()) return null
            var working = rawText.replace(BIDI_AND_FORMAT_CHARS, "").trim()
            if (working.isEmpty()) return null
            // Any whitespace indicates a search query or placeholder ("Search or type web address").
            if (working.any { it.isWhitespace() }) return null

            val lower = working.lowercase()
            when {
                lower.startsWith("http://") -> working = working.substring(7)
                lower.startsWith("https://") -> working = working.substring(8)
                lower.contains("://") -> return null // chrome://, file://, about://, content://, intent://
                lower.startsWith("about:") || lower.startsWith("javascript:") || lower.startsWith("data:") -> return null
            }

            // Strip path, query, and fragment before inspecting authority.
            val authorityEnd = working.indexOfAny(charArrayOf('/', '?', '#'))
            val authority = if (authorityEnd >= 0) working.substring(0, authorityEnd) else working
            if (authority.isEmpty()) return null

            // Strip optional userinfo (`user:pass@host`).
            val hostPort = authority.substringAfterLast('@')
            if (hostPort.isEmpty() || hostPort.startsWith('[')) return null // IPv6 literals are not DNS names

            // Strip optional `:port`.
            val colonIdx = hostPort.indexOf(':')
            val rawHost = if (colonIdx >= 0) {
                val portPart = hostPort.substring(colonIdx + 1)
                if (portPart.isEmpty() || !portPart.all { it.isDigit() }) return null
                hostPort.substring(0, colonIdx)
            } else {
                hostPort
            }

            val normalized = DnsFilterPolicy.normalize(rawHost)
            if (normalized.isEmpty() || '.' !in normalized) return null
            val labels = normalized.split('.')
            if (labels.size < 2 || labels.any { !HOST_LABEL.matches(it) }) return null
            val tld = labels.last()
            // Reject IPv4 literals (`1.2.3.4`) and single-character TLDs.
            if (tld.length < 2 || ALL_DIGITS.matches(tld)) return null
            return normalized
        }
    }
}
