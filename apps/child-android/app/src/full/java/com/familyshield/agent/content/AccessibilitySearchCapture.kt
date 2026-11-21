package com.familyshield.agent.content

import android.view.accessibility.AccessibilityEvent
import android.view.accessibility.AccessibilityNodeInfo
import com.familyshield.agent.data.ConsentState
import com.familyshield.agent.data.RuleRepository
import com.familyshield.agent.social.SocialScanQueue
import javax.inject.Inject
import javax.inject.Singleton

/**
 * ADR-0039 / osra-security#44 & #45 (Full flavor only): verifies window ownership across all input
 * sources before inspecting nodes, requires explicit [RuleRepository.searchMonitoringEnabled] opt-in
 * and active consent, and enqueues only confirmed submitted search queries (never URLs) into the
 * durable [SocialScanQueue] (`pending_scans`) for `POST /v1/content/search-event`.
 */
@Singleton
class AccessibilitySearchCapture internal constructor(
    private val rules: RuleRepository?,
    private val consent: ConsentState?,
    private val isPausedProvider: () -> Boolean,
    private val searchMonitoringEnabledProvider: () -> Boolean,
    private val enqueueSearch: (engine: String, query: String, nowMs: Long) -> Unit,
) : SearchCapture {

    @Inject
    constructor(
        rules: RuleRepository,
        queue: SocialScanQueue,
        consent: ConsentState,
    ) : this(
        rules = rules,
        consent = consent,
        isPausedProvider = { consent.isPaused() },
        searchMonitoringEnabledProvider = { rules.searchMonitoringEnabled() },
        enqueueSearch = { engine, query, nowMs -> queue.enqueueSearch(engine = engine, query = query, nowMs = nowMs) },
    )

    private val lock = Any()
    private val recentSearches = LinkedHashMap<String, Long>()
    private var lastScanAtMs: Long = 0L

    override fun onAccessibilityEvent(
        event: AccessibilityEvent,
        foregroundPackage: String?,
        activeRootProvider: (() -> AccessibilityNodeInfo?)?,
        nowMs: Long,
    ) {
        if (consent != null && consent.isPaused()) return // ADR-0008 §3
        if (rules != null && !rules.searchMonitoringEnabled()) return
        captureFromWindow(
            foregroundPackage = foregroundPackage,
            eventPackage = event.packageName?.toString(),
            activeRootProvider = { activeRootProvider?.invoke()?.let(::PlatformReadableNode) },
            eventSourceProvider = { event.source?.let(::PlatformReadableNode) },
            nowMs = nowMs,
        )
    }

    /**
     * Pure capture flow operating on [ReadableNode]s (`osra-security#44` & `#45`). Enforces consent,
     * explicit opt-in, event package ownership, and debounce before acquiring sources inside `try/finally`,
     * and verifies descendant ownership before inspecting any text or children.
     */
    internal fun captureFromWindow(
        foregroundPackage: String?,
        eventPackage: String?,
        activeRootProvider: () -> ReadableNode?,
        eventSourceProvider: () -> ReadableNode? = { null },
        nowMs: Long = System.currentTimeMillis(),
    ): Boolean {
        if (isPausedProvider()) return false
        if (!searchMonitoringEnabledProvider()) return false
        val pkg = foregroundPackage?.takeIf { SearchQueryParser.isSupportedPackage(it) } ?: return false
        if (eventPackage != pkg) return false
        synchronized(lock) {
            if (nowMs - lastScanAtMs < SCAN_DEBOUNCE_MS) return false
        }

        var activeRoot: ReadableNode? = null
        var eventSource: ReadableNode? = null
        val nodes = ArrayList<SearchNodeSnapshot>(16)
        val nonControlVisibleCount: Int
        try {
            activeRoot = activeRootProvider()
            eventSource = eventSourceProvider()
            val verifiedRoot = WindowOwnershipPolicy.selectVerifiedRoot(
                expectedPackage = pkg,
                eventPackage = eventPackage,
                isPackageEligible = { SearchQueryParser.isSupportedPackage(it) && searchMonitoringEnabledProvider() },
                activeRoot = activeRoot,
                eventSource = eventSource,
            ) ?: return false

            synchronized(lock) {
                if (nowMs - lastScanAtMs < SCAN_DEBOUNCE_MS) return false
                lastScanAtMs = nowMs
            }
            nonControlVisibleCount = collectNodes(verifiedRoot, pkg, nodes, depth = 0, totalVisited = intArrayOf(0))
        } finally {
            runCatching { activeRoot?.recycle() }
            if (eventSource !== activeRoot) {
                runCatching { eventSource?.recycle() }
            }
        }

        val parsed = SearchQueryParser.extractFromNodes(
            packageId = pkg,
            nodes = nodes,
            hasAppResultsContent = nonControlVisibleCount >= 3,
        ) ?: return false
        val dedupeKey = SearchQueryParser.dedupeKey(parsed)
        synchronized(lock) {
            if (!SearchQueryParser.shouldSend(recentSearches[dedupeKey], nowMs)) return false
            recentSearches[dedupeKey] = nowMs
            while (recentSearches.size > MAX_CACHE_ENTRIES) {
                val eldest = recentSearches.entries.firstOrNull()?.key ?: break
                recentSearches.remove(eldest)
            }
        }

        enqueueSearch(parsed.engine, parsed.query, nowMs)
        return true
    }

    /**
     * Collects text strictly from provenance-verified controls ([SearchQueryParser.isVerifiedControlMetadata]);
     * ordinary content descendants are counted for results-structure gating without reading their text.
     */
    private fun collectNodes(
        node: ReadableNode?,
        expectedPackage: String,
        out: MutableList<SearchNodeSnapshot>,
        depth: Int,
        totalVisited: IntArray,
    ): Int {
        if (node == null || depth > MAX_DEPTH || totalVisited[0] >= MAX_NODES) return 0
        if (node.packageName != expectedPackage) return 0
        if (!node.isVisibleToUser) return 0
        totalVisited[0]++

        val viewId = node.viewIdResourceName
        val className = node.className?.toString()
        var nonControlVisible = 0
        if (SearchQueryParser.isVerifiedControlMetadata(expectedPackage, viewId, className)) {
            val text = node.text?.toString() ?: node.contentDescription?.toString()
            if (!text.isNullOrBlank()) {
                out.add(
                    SearchNodeSnapshot(
                        text = text,
                        viewIdResourceName = viewId,
                        className = className,
                        isEditable = node.isEditable,
                        isFocused = node.isFocused,
                    ),
                )
            }
        } else if (depth > 0) {
            nonControlVisible = 1
        }
        for (i in 0 until node.childCount) {
            val child = node.getChild(i) ?: continue
            try {
                nonControlVisible += collectNodes(child, expectedPackage, out, depth + 1, totalVisited)
            } finally {
                runCatching { child.recycle() }
            }
            if (totalVisited[0] >= MAX_NODES) break
        }
        return nonControlVisible
    }

    companion object {
        private const val SCAN_DEBOUNCE_MS = 600L
        private const val MAX_DEPTH = 14
        private const val MAX_NODES = 120
        private const val MAX_CACHE_ENTRIES = 128
    }
}
