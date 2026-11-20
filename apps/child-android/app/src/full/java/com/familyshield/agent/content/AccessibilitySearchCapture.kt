package com.familyshield.agent.content

import android.util.Log
import android.view.accessibility.AccessibilityEvent
import android.view.accessibility.AccessibilityNodeInfo
import com.familyshield.agent.data.AgentSettings
import com.familyshield.agent.data.ConsentState
import com.familyshield.agent.data.RuleRepository
import com.familyshield.agent.network.ApiService
import com.familyshield.agent.network.dto.SearchEventDto
import java.time.Instant
import javax.inject.Inject
import javax.inject.Singleton
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.launch

/**
 * ADR-0039 / #939 (Full flavor only): extracts submitted search queries from Chrome, supported
 * browsers, Google App, and YouTube via the accessibility node tree and reports them to
 * `POST /v1/content/search-event`. Honours [ConsentState.isPaused] and [RuleRepository.searchMonitoringEnabled].
 */
@Singleton
class AccessibilitySearchCapture @Inject constructor(
    private val api: ApiService,
    private val settings: AgentSettings,
    private val rules: RuleRepository,
    private val consent: ConsentState,
) : SearchCapture {

    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    private val lock = Any()
    private val recentSearches = LinkedHashMap<String, Long>()
    private var lastScanAtMs: Long = 0L

    override fun onAccessibilityEvent(
        event: AccessibilityEvent,
        foregroundPackage: String?,
        activeRootProvider: (() -> AccessibilityNodeInfo?)?,
        nowMs: Long,
    ) {
        if (consent.isPaused()) return // ADR-0008 §3
        if (!rules.searchMonitoringEnabled()) return
        val pkg = listOfNotNull(foregroundPackage, event.packageName?.toString())
            .firstOrNull { SearchQueryParser.isSupportedPackage(it) } ?: return
        synchronized(lock) {
            if (nowMs - lastScanAtMs < SCAN_DEBOUNCE_MS) return
            lastScanAtMs = nowMs
        }

        val nodes = ArrayList<SearchNodeSnapshot>(64)
        val root = activeRootProvider?.invoke() ?: event.source
        if (root != null) {
            try {
                collectNodes(root, nodes, depth = 0)
            } finally {
                runCatching { root.recycle() }
            }
        }
        val parsed = SearchQueryParser.extractFromNodes(pkg, nodes) ?: return
        val dedupeKey = SearchQueryParser.dedupeKey(parsed)
        synchronized(lock) {
            if (!SearchQueryParser.shouldSend(recentSearches[dedupeKey], nowMs)) return
            recentSearches[dedupeKey] = nowMs
            while (recentSearches.size > MAX_CACHE_ENTRIES) {
                val eldest = recentSearches.entries.firstOrNull()?.key ?: break
                recentSearches.remove(eldest)
            }
        }

        scope.launch {
            if (consent.isPaused()) return@launch
            val childId = settings.childId() ?: return@launch
            val deviceId = settings.deviceId() ?: return@launch
            try {
                api.postSearchEvent(
                    SearchEventDto(
                        childId = childId,
                        deviceId = deviceId,
                        engine = parsed.engine,
                        query = parsed.query,
                        url = parsed.url,
                        timestamp = Instant.ofEpochMilli(nowMs).toString(),
                    ),
                )
            } catch (e: CancellationException) {
                throw e
            } catch (e: Exception) {
                // Allow retry on transient failure without logging sensitive search text.
                synchronized(lock) { recentSearches.remove(dedupeKey) }
                Log.w(TAG, "search event upload failed: ${e.javaClass.simpleName}")
            }
        }
    }

    private fun collectNodes(node: AccessibilityNodeInfo?, out: MutableList<SearchNodeSnapshot>, depth: Int) {
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
        private const val TAG = "SearchCapture"
        private const val SCAN_DEBOUNCE_MS = 600L
        private const val MAX_DEPTH = 14
        private const val MAX_NODES = 120
        private const val MAX_CACHE_ENTRIES = 128
    }
}
