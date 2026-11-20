package com.familyshield.agent.social

import android.view.accessibility.AccessibilityEvent
import android.view.accessibility.AccessibilityNodeInfo
import com.familyshield.agent.data.ConsentState
import com.familyshield.agent.data.RuleRepository
import javax.inject.Inject
import javax.inject.Singleton

/**
 * Feature #2/#17 social capture: extension of the accessibility pipeline. When the foreground
 * package maps to a monitored app (whatsapp/instagram/tiktok/snapchat/twitter/discord/roblox/line)
 * and the rule set does not opt that app out (absent socialMonitoring key = enabled), the visible
 * node tree is walked (text + content-description, visible nodes only, capped at
 * [MAX_CAPTURE_CHARS] chars per event), a likely contact + message candidate are extracted,
 * the message is redacted (TextRedaction) and queued for server-side AI scanning
 * (SocialScanQueue). Debounced to one capture per package per 1500 ms.
 */
@Singleton
class SocialCapture @Inject constructor(
    private val rules: RuleRepository,
    private val queue: SocialScanQueue,
    private val consent: ConsentState,
) {
    private val lock = Any()
    private val lastCaptureAt = HashMap<String, Long>()

    /** Entry point from AccessibilityMonitorService; cheap no-op for unmonitored packages. */
    fun onAccessibilityEvent(
        event: AccessibilityEvent,
        nowMs: Long = System.currentTimeMillis(),
        foregroundPackage: String? = null,
        activeRootProvider: (() -> AccessibilityNodeInfo?)? = null,
    ) {
        if (consent.isPaused()) return // ADR-0008 §3
        val (_, appKey) = SocialHeuristics.resolveMonitoredApp(
            foregroundPackage = foregroundPackage,
            eventPackage = event.packageName?.toString(),
        ) ?: return
        if (!rules.socialMonitoringEnabled(appKey)) return
        synchronized(lock) {
            if (!SocialHeuristics.shouldCapture(lastCaptureAt[SocialHeuristics.debounceKey(appKey)], nowMs)) return
        }
        val texts = ArrayList<String>()
        val activeRoot = activeRootProvider?.invoke()
        if (activeRoot != null) {
            try {
                collectVisibleText(activeRoot, StringBuilder(), texts)
            } finally {
                activeRoot.recycle()
            }
        } else {
            val root = event.source
            if (root != null) {
                try {
                    collectVisibleText(root, StringBuilder(), texts)
                } finally {
                    root.recycle()
                }
            }
        }
        val (contact, candidates) = SocialHeuristics.extractCandidates(texts)
        val redacted = candidates.mapNotNull { candidate ->
            TextRedaction.redact(candidate).takeIf { it.isNotBlank() }
        }
        if (redacted.isEmpty()) return
        synchronized(lock) {
            if (!SocialHeuristics.shouldCapture(lastCaptureAt[SocialHeuristics.debounceKey(appKey)], nowMs)) return
            lastCaptureAt[SocialHeuristics.debounceKey(appKey)] = nowMs
        }
        for (msg in redacted) {
            queue.enqueue(appKey, contact, msg)
        }
    }

    /** Depth-first collection of visible text/content-desc, stopping at [MAX_CAPTURE_CHARS]. */
    private fun collectVisibleText(node: AccessibilityNodeInfo?, budget: StringBuilder, out: MutableList<String>) {
        if (node == null || !node.isVisibleToUser || budget.length >= MAX_CAPTURE_CHARS) return
        val text = node.text?.toString() ?: node.contentDescription?.toString()
        if (!text.isNullOrBlank()) {
            out.add(text)
            budget.append(text).append('\n')
        }
        for (i in 0 until node.childCount) {
            val child = node.getChild(i)
            collectVisibleText(child, budget, out)
            child?.recycle()
            if (budget.length >= MAX_CAPTURE_CHARS) return
        }
    }

    companion object {
        /** Max characters collected from the node tree per accessibility event. */
        const val MAX_CAPTURE_CHARS: Int = 4000
    }
}
