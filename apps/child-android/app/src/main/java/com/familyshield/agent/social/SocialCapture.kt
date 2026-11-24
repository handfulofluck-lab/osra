package com.familyshield.agent.social

import android.view.accessibility.AccessibilityEvent
import android.view.accessibility.AccessibilityNodeInfo
import com.familyshield.agent.content.PlatformReadableNode
import com.familyshield.agent.content.ReadableNode
import com.familyshield.agent.content.WindowOwnershipPolicy
import com.familyshield.agent.data.ConsentState
import com.familyshield.agent.data.RuleRepository
import javax.inject.Inject
import javax.inject.Singleton

/**
 * Feature #2/#17 social capture: extension of the accessibility pipeline. When the foreground
 * package maps to a monitored app and the rule set does not opt that app out, verifies window
 * ownership across all input sources (`osra-security#44`) before walking visible text (up to
 * [MAX_CAPTURE_CHARS] chars per event), redacts and queues for server-side AI scanning.
 * Debounced to one capture per package per 1500 ms.
 */
@Singleton
class SocialCapture internal constructor(
    private val isPausedProvider: () -> Boolean,
    private val socialMonitoringProvider: (String) -> Boolean,
    private val enqueueCapture: (appKey: String, contact: String?, text: String, nowMs: Long) -> Unit,
) {
    @Inject
    constructor(
        rules: RuleRepository,
        queue: SocialScanQueue,
        consent: ConsentState,
        @dagger.hilt.android.qualifiers.ApplicationContext context: android.content.Context,
    ) : this(
        isPausedProvider = { consent.isPaused() },
        socialMonitoringProvider = { appKey -> rules.socialMonitoringEnabled(appKey) },
        enqueueCapture = { appKey, contact, msg, _ ->
            if (TestChatCaptureGate.allows(context, appKey, contact)) {
                queue.enqueue(appKey, contact, msg)
            }
        },
    )

    private val lock = Any()
    private val lastCaptureAt = HashMap<String, Long>()

    /** Entry point from AccessibilityMonitorService; cheap no-op for unmonitored packages. */
    fun onAccessibilityEvent(
        event: AccessibilityEvent,
        nowMs: Long = System.currentTimeMillis(),
        foregroundPackage: String? = null,
        activeRootProvider: (() -> AccessibilityNodeInfo?)? = null,
    ) {
        if (isPausedProvider()) return // ADR-0008 §3
        captureFromWindow(
            foregroundPackage = foregroundPackage,
            eventPackage = event.packageName?.toString(),
            activeRootProvider = { activeRootProvider?.invoke()?.let(::PlatformReadableNode) },
            eventSourceProvider = { event.source?.let(::PlatformReadableNode) },
            nowMs = nowMs,
        )
    }

    /**
     * Pure capture flow operating on [ReadableNode]s (`osra-security#44`). Declines collection
     * immediately without acquiring or reading any nodes when eligibility or event owner fails,
     * acquires window sources strictly inside the `try/finally` cleanup block, and verifies
     * descendant ownership before reading text or traversing children.
     */
    internal fun captureFromWindow(
        foregroundPackage: String?,
        eventPackage: String?,
        activeRootProvider: () -> ReadableNode?,
        eventSourceProvider: () -> ReadableNode? = { null },
        nowMs: Long = System.currentTimeMillis(),
    ): Boolean {
        if (isPausedProvider()) return false // ADR-0008 §3
        val appKey = foregroundPackage?.let(MonitoredApps::appKeyFor) ?: return false
        if (!socialMonitoringProvider(appKey)) return false
        if (eventPackage != foregroundPackage) return false
        synchronized(lock) {
            if (!SocialHeuristics.shouldCapture(lastCaptureAt[SocialHeuristics.debounceKey(appKey)], nowMs)) return false
        }
        var activeRoot: ReadableNode? = null
        var eventSource: ReadableNode? = null
        try {
            activeRoot = activeRootProvider()
            eventSource = eventSourceProvider()
            val verifiedRoot = WindowOwnershipPolicy.selectVerifiedRoot(
                expectedPackage = foregroundPackage,
                eventPackage = eventPackage,
                isPackageEligible = { pkg ->
                    val key = MonitoredApps.appKeyFor(pkg) ?: return@selectVerifiedRoot false
                    socialMonitoringProvider(key)
                },
                activeRoot = activeRoot,
                eventSource = eventSource,
            ) ?: return false

            val texts = ArrayList<String>()
            collectVisibleText(verifiedRoot, foregroundPackage, StringBuilder(), texts)
            val (contact, candidates) = SocialHeuristics.extractCandidates(texts)
            val redacted = candidates.mapNotNull { candidate ->
                TextRedaction.redact(candidate).takeIf { it.isNotBlank() }
            }
            if (redacted.isEmpty()) return false
            synchronized(lock) {
                if (!SocialHeuristics.shouldCapture(lastCaptureAt[SocialHeuristics.debounceKey(appKey)], nowMs)) return false
                lastCaptureAt[SocialHeuristics.debounceKey(appKey)] = nowMs
            }
            for (msg in redacted) {
                enqueueCapture(appKey, contact, msg, nowMs)
            }
            return true
        } finally {
            runCatching { activeRoot?.recycle() }
            if (eventSource !== activeRoot) {
                runCatching { eventSource?.recycle() }
            }
        }
    }

    /** Depth-first collection of visible text/content-desc for verified descendants only, stopping at [MAX_CAPTURE_CHARS]. */
    private fun collectVisibleText(node: ReadableNode?, expectedPackage: String, budget: StringBuilder, out: MutableList<String>) {
        if (node == null || budget.length >= MAX_CAPTURE_CHARS) return
        if (node.packageName != expectedPackage) return
        if (!node.isVisibleToUser) return
        val text = node.text?.toString() ?: node.contentDescription?.toString()
        if (!text.isNullOrBlank()) {
            out.add(text)
            budget.append(text).append('\n')
        }
        for (i in 0 until node.childCount) {
            val child = node.getChild(i)
            collectVisibleText(child, expectedPackage, budget, out)
            child?.recycle()
            if (budget.length >= MAX_CAPTURE_CHARS) return
        }
    }

    companion object {
        /** Max characters collected from the node tree per accessibility event. */
        const val MAX_CAPTURE_CHARS: Int = 4000
    }
}
