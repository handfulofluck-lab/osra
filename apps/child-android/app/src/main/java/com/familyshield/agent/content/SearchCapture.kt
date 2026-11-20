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
 * Pure JVM parser + dedupe policy for search safety (#939, ADR-0039).
 *
 * Extracts submitted queries from:
 *  1. Search results URLs (Google search URLs with q=, Bing, DuckDuckGo, Yahoo p=, YouTube search_query=).
 *  2. SERP page titles ("<query> - Google Search", "<query> - بحث Google", "<query> - Bing").
 *  3. Unfocused search-box / submitted query nodes when a browser is on a search host or inside
 *     YouTube / Google Search results. Focused editable fields are ignored so half-typed keystrokes
 *     never flood the endpoint.
 */
object SearchQueryParser {

    const val MIN_QUERY_LEN: Int = 2
    const val MAX_QUERY_LEN: Int = 200
    const val DEDUPE_WINDOW_MS: Long = 5 * 60_000L

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

    private val APP_ENGINES: Map<String, String> = mapOf(
        "com.google.android.youtube" to "youtube",
        "com.google.android.apps.youtube.kids" to "youtube",
        "com.google.android.googlequicksearchbox" to "google",
    )

    private val GOOGLE_SEARCH_HOST_RE = Regex("^(?:www\\.|m\\.)?google\\.[a-z]{2,3}(?:\\.[a-z]{2,3})?$")
    private val SEARCH_TITLE_SUFFIXES = listOf(
        " - Google Search",
        " - بحث Google",
        " - Google",
        " - Bing",
        " at DuckDuckGo",
        " — DuckDuckGo",
        " - DuckDuckGo",
    )
    private val PLACEHOLDERS = setOf(
        "search",
        "search google",
        "search google or type url",
        "search or type url",
        "search or type web address",
        "search youtube",
        "search web",
        "type a message",
        "google",
        "google search",
        "youtube",
        "بحث",
        "ابحث هنا",
        "البحث في google أو كتابة عنوان url",
    )

    fun isSupportedPackage(packageId: String?): Boolean {
        if (packageId.isNullOrBlank()) return false
        return packageId in BROWSER_PACKAGES || packageId in APP_ENGINES
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

    /** Extracts a submitted search from the visible accessibility nodes of [packageId]. */
    fun extractFromNodes(packageId: String?, nodes: List<SearchNodeSnapshot>): ParsedSearch? {
        if (!isSupportedPackage(packageId) || nodes.isEmpty()) return null

        // 1. Exact search URL in any non-focused node (Chrome url_bar, WebView, SBrowser URL bar).
        for (node in nodes) {
            if (node.isFocused) continue
            parseSearchUrl(node.text)?.let { return it }
        }

        // 2. Search-page window/tab title (`"<query> - Google Search"`, etc.).
        for (node in nodes) {
            val trimmed = node.text.trim()
            for (suffix in SEARCH_TITLE_SUFFIXES) {
                if (trimmed.endsWith(suffix) && trimmed.length > suffix.length + 1) {
                    val raw = trimmed.removeSuffix(suffix)
                    val query = normalizeQuery(raw) ?: continue
                    val engine = when {
                        suffix.contains("Bing") -> "bing"
                        suffix.contains("DuckDuckGo") -> "duckduckgo"
                        else -> "google"
                    }
                    return ParsedSearch(engine = engine, query = query)
                }
            }
        }

        // 3. Dedicated app or active search engine page with unfocused search field.
        val engineHint = APP_ENGINES[packageId] ?: detectBrowserEngineHint(nodes) ?: return null
        if (nodes.size < 4) return null // wait until results/screen content are visible, not empty search home
        for (node in nodes) {
            if (node.isFocused) continue
            val isSearchField = node.isEditable ||
                (node.className?.endsWith("EditText") == true) ||
                (node.viewIdResourceName?.let { id ->
                    id.contains("search_src_text") || id.contains("search_plate") ||
                        id.contains("search_box") || id.contains("query") || id.contains("search_query")
                } == true)
            if (!isSearchField) continue
            val query = normalizeQuery(node.text) ?: continue
            if (looksLikeUrlOrHost(query)) continue
            return ParsedSearch(engine = engineHint, query = query)
        }
        return null
    }

    /** Dedupe key: same engine + case-folded normalized query. */
    fun dedupeKey(parsed: ParsedSearch): String = "${parsed.engine}:${parsed.query.lowercase()}"

    fun shouldSend(lastSentAtMs: Long?, nowMs: Long, windowMs: Long = DEDUPE_WINDOW_MS): Boolean =
        lastSentAtMs == null || nowMs - lastSentAtMs >= windowMs

    private fun detectBrowserEngineHint(nodes: List<SearchNodeSnapshot>): String? {
        for (node in nodes) {
            val lower = node.text.trim().lowercase().removePrefix("https://").removePrefix("http://")
            val host = lower.substringBefore('/').substringBefore('?').substringBefore(':')
            if (GOOGLE_SEARCH_HOST_RE.matches(host)) return "google"
            if (host == "www.bing.com" || host == "bing.com") return "bing"
            if (host == "duckduckgo.com" || host == "www.duckduckgo.com") return "duckduckgo"
            if (host == "m.youtube.com" || host == "www.youtube.com") return "youtube"
        }
        return null
    }

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
        if (collapsed.lowercase() in PLACEHOLDERS) return null
        if (collapsed.all { it.isDigit() || !it.isLetterOrDigit() }) return null
        return collapsed
    }

    private fun looksLikeUrlOrHost(text: String): Boolean {
        val t = text.lowercase()
        return t.startsWith("http://") || t.startsWith("https://") ||
            (!t.contains(' ') && Regex("^[a-z0-9-]+(\\.[a-z0-9-]+)+(/.*)?$").matches(t))
    }
}
