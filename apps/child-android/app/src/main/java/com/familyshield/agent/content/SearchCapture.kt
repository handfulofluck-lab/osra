package com.familyshield.agent.content

import android.view.accessibility.AccessibilityEvent
import android.view.accessibility.AccessibilityNodeInfo
import java.net.URLDecoder
import java.nio.charset.StandardCharsets

/**
 * ADR-0039 / #939: Flavor boundary for search-query capture. `play` binds [NoopSearchCapture]
 * (collects and sends nothing); `full` binds `AccessibilitySearchCapture`, which reads submitted
 * searches on supported browsers/search apps and posts to `POST /v1/content/search-event`.
 */
interface SearchCapture {
    fun onAccessibilityEvent(
        event: AccessibilityEvent,
        foregroundPackage: String?,
        activeRootProvider: (() -> AccessibilityNodeInfo?)? = null,
        nowMs: Long = System.currentTimeMillis(),
    ) {}
}

/** Pure snapshot of one visible accessibility node for JVM-tested search extraction. */
data class SearchNodeSnapshot(
    val text: String,
    val viewIdResourceName: String? = null,
    val className: String? = null,
    val isEditable: Boolean = false,
    val isFocused: Boolean = false,
)

/** Extracted search event ready for enqueueing to `POST /v1/content/search-event` (osra-security#45). */
data class ParsedSearch(
    val engine: String,
    val query: String,
)

/**
 * Pure JVM parser + dedupe policy for search safety (#939, ADR-0039, `osra-security#58`).
 *
 * Restricts search extraction strictly to provenance-verified native browser address controls
 * ([BROWSER_ADDRESS_BAR_IDS] owned by a supported browser package in [BROWSER_PACKAGES], unfocused)
 * carrying an exact search-results URL (`q=`, `p=`, `search_query=`).
 *
 * Ordinary page nodes (`TextView`, `WebView`, rendered HTML content, unfocused page inputs,
 * unverified dedicated-app search boxes lacking an app-owned results marker, or missing
 * address-bar provenance) are ignored and left off for this cut.
 */
object SearchQueryParser {

    const val MIN_QUERY_LEN: Int = 2
    const val MAX_QUERY_LEN: Int = 200
    const val DEDUPE_WINDOW_MS: Long = 5 * 60_000L

    private val BROWSER_ADDRESS_BAR_IDS: Set<String> = setOf(
        "url_bar",
        "url_bar_text",
        "location_bar_edit_text",
        "omnibox_text",
        "mozac_browser_toolbar_url_view",
        "search_box_text",
    )

    private val BROWSER_PACKAGES: Set<String> = setOf(
        "com.android.chrome",
        "com.chrome.beta",
        "com.chrome.dev",
        "com.sec.android.app.sbrowser",
        "org.mozilla.firefox",
        "com.microsoft.emmx",
        "com.opera.browser",
        "com.duckduckgo.mobile.android",
    )

    private val GOOGLE_SEARCH_HOST_RE = Regex("^(?:www\\.|m\\.)?google\\.[a-z]{2,3}(?:\\.[a-z]{2,3})?$")

    fun isSupportedPackage(packageId: String?): Boolean {
        if (packageId.isNullOrBlank()) return false
        return packageId in BROWSER_PACKAGES
    }

    /** Parses a search results URL string (with or without explicit scheme); returns null when not a search URL. */
    fun parseSearchUrl(rawText: String): ParsedSearch? {
        val candidate = rawText.trim()
        if (candidate.isEmpty() || candidate.length > 2048 || candidate.contains(' ')) return null
        val lower = candidate.lowercase()
        val withScheme = when {
            lower.startsWith("http://") || lower.startsWith("https://") -> candidate
            lower.contains("/") && lower.contains("?") && !lower.contains("://") -> "https://$candidate"
            else -> return null
        }
        val schemeSplit = withScheme.indexOf("://")
        val afterScheme = withScheme.substring(schemeSplit + 3)
        val slashIdx = afterScheme.indexOf('/')
        val queryIdx = afterScheme.indexOf('?')
        if (queryIdx < 0) return null
        val hostEnd = listOf(slashIdx, queryIdx).filter { it >= 0 }.minOrNull() ?: afterScheme.length
        val host = afterScheme.substring(0, hostEnd).substringBefore(':').lowercase()
        val path = if (slashIdx in 0 until queryIdx) afterScheme.substring(slashIdx, queryIdx).lowercase() else ""
        val rawQuery = afterScheme.substring(queryIdx + 1).substringBefore('#')

        val (engine, paramName) = when {
            GOOGLE_SEARCH_HOST_RE.matches(host) && (path.startsWith("/search") || path.startsWith("/m/search")) ->
                "google" to "q"
            (host == "www.bing.com" || host == "bing.com") && path.startsWith("/search") ->
                "bing" to "q"
            (host == "duckduckgo.com" || host == "www.duckduckgo.com" || host == "start.duckduckgo.com") ->
                "duckduckgo" to "q"
            host == "search.yahoo.com" && path.startsWith("/search") ->
                "yahoo" to "p"
            (host == "www.youtube.com" || host == "m.youtube.com" || host == "youtube.com") && path.startsWith("/results") ->
                "youtube" to "search_query"
            else -> return null
        }
        val value = extractQueryParam(rawQuery, paramName) ?: return null
        val cleaned = normalizeQuery(value) ?: return null
        return ParsedSearch(engine = engine, query = cleaned)
    }

    /** True when raw node metadata identifies a proven native browser address bar control. */
    fun isVerifiedControlMetadata(
        packageId: String?,
        viewIdResourceName: String?,
        className: CharSequence?,
    ): Boolean {
        val pkg = packageId?.takeIf { it in BROWSER_PACKAGES } ?: return false
        if (className?.toString() == "android.webkit.WebView") return false
        return verifiedResourceId(pkg, viewIdResourceName, BROWSER_ADDRESS_BAR_IDS)
    }

    /** True when [node] is a verified native browser address control owned by [packageId]. */
    fun isVerifiedBrowserAddressControl(packageId: String?, node: SearchNodeSnapshot): Boolean =
        isVerifiedControlMetadata(packageId, node.viewIdResourceName, node.className)

    private fun verifiedResourceId(
        packageId: String,
        viewIdResourceName: String?,
        allowedIds: Set<String>,
    ): Boolean {
        val raw = viewIdResourceName?.trim()?.takeIf { it.isNotEmpty() } ?: return false
        val colon = raw.indexOf(":id/")
        val entryName = if (colon >= 0) {
            if (raw.substring(0, colon) != packageId) return false
            raw.substring(colon + 4)
        } else {
            if (raw.contains(':')) return false
            raw
        }
        return entryName in allowedIds
    }

    /** Extracts a submitted search strictly from verified native browser address controls with a results URL. */
    fun extractFromNodes(
        packageId: String?,
        nodes: List<SearchNodeSnapshot>,
    ): ParsedSearch? {
        if (packageId !in BROWSER_PACKAGES || nodes.isEmpty()) return null
        for (node in nodes) {
            if (node.isFocused || !isVerifiedBrowserAddressControl(packageId, node)) continue
            parseSearchUrl(node.text)?.let { return it }
        }
        return null
    }

    /** Dedupe key: same engine + case-folded normalized query. */
    fun dedupeKey(parsed: ParsedSearch): String = "${parsed.engine}:${parsed.query.lowercase()}"

    fun shouldSend(lastSentAtMs: Long?, nowMs: Long, windowMs: Long = DEDUPE_WINDOW_MS): Boolean =
        lastSentAtMs == null || nowMs - lastSentAtMs >= windowMs

    private fun extractQueryParam(rawQuery: String, key: String): String? {
        for (part in rawQuery.split('&')) {
            val eq = part.indexOf('=')
            val k = if (eq >= 0) part.substring(0, eq) else part
            if (k == key && eq >= 0) {
                return runCatching { URLDecoder.decode(part.substring(eq + 1), StandardCharsets.UTF_8.name()) }
                    .getOrNull()
            }
        }
        return null
    }

    private fun normalizeQuery(raw: String): String? {
        val collapsed = raw.trim().replace(Regex("\\s+"), " ")
        if (collapsed.length !in MIN_QUERY_LEN..MAX_QUERY_LEN) return null
        if (collapsed.all { it.isDigit() || !it.isLetterOrDigit() }) return null
        return collapsed
    }
}
