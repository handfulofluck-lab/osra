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
        val eventSourceNode = event.source
        captureFromWindow(
            foregroundPackage = foregroundPackage,
            eventPackage = event.packageName?.toString(),
            activeRootProvider = { activeRootProvider?.invoke()?.let(::PlatformReadableNode) },
            eventSourceProvider = { eventSourceNode?.let(::PlatformReadableNode) },
            nowMs = nowMs,
        )
    }

    /**
     * Pure capture flow operating on [ReadableNode]s (`osra-security#44` & `#45`). Enforces consent,
     * explicit opt-in, and verified window ownership before any node/text access, and enqueues
     * submitted queries to the durable queue without URLs.
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
        synchronized(lock) {
            if (nowMs - lastScanAtMs < SCAN_DEBOUNCE_MS) return false
        }

        val activeRoot = activeRootProvider()
        val eventSource = eventSourceProvider()
        val nodes = ArrayList<SearchNodeSnapshot>(64)
        try {
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
            collectNodes(verifiedRoot, nodes, depth = 0)
        } finally {
            runCatching { activeRoot?.recycle() }
            if (eventSource !== activeRoot) {
                runCatching { eventSource?.recycle() }
            }
        }

        val parsed = SearchQueryParser.extractFromNodes(pkg, nodes) ?: return false
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

    private fun collectNodes(node: ReadableNode?, out: MutableList<SearchNodeSnapshot>, depth: Int) {
        if (node == null || depth > MAX_DEPTH || out.size >= MAX_NODES || !node.isVisibleToUser) return
        val text = node.text?.toString() ?: node.contentDescription?.toString()
        if (!text.isNullOrBlank()) {
            out.add(
                SearchNodeSnapshot(
                    text = text,
                    viewIdResourceName = node.viewIdResourceName,
                    className = node.className?.toString(),
                    isEditable = node.isEditable,
                    isFocused = node.isFocused,
                ),
            )
        }
        for (i in 0 until node.childCount) {
            val child = node.getChild(i) ?: continue
            try {
                collectNodes(child, out, depth + 1)
            } finally {
                runCatching { child.recycle() }
            }
            if (out.size >= MAX_NODES) return
        }
    }

    companion object {
        private const val SCAN_DEBOUNCE_MS = 600L
        private const val MAX_DEPTH = 14
        private const val MAX_NODES = 120
        private const val MAX_CACHE_ENTRIES = 128
    }
}
