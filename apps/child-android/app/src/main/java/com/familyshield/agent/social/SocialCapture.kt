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
 * [MAX_CAPTURE_CHARS] chars per event). WhatsApp/WhatsApp Business queues every new visible
 * conversation bubble through a bounded per-conversation tracker; other monitored apps keep the
 * existing single-candidate heuristic. Text is redacted (TextRedaction) and queued for server-side
 * AI scanning (SocialScanQueue). Debounced to one capture per package per 1500 ms.
 */
@Singleton
class SocialCapture @Inject constructor(
    private val rules: RuleRepository,
    private val queue: SocialScanQueue,
    private val consent: ConsentState,
    @dagger.hilt.android.qualifiers.ApplicationContext private val context: android.content.Context,
) {
    private val lock = Any()
    private val lastCaptureAt = HashMap<String, Long>()
    private val conversationSeen = ConversationCapturePolicy.SeenTracker()

    init {
        consent.addListener { paused ->
            if (paused) conversationSeen.clear()
        }
        rules.addRulesChangedListener {
            conversationSeen.retainOnly { appKey -> rules.socialMonitoringEnabled(appKey) }
        }
    }

    /** Entry point from AccessibilityMonitorService; cheap no-op for unmonitored packages. */
    fun onAccessibilityEvent(event: AccessibilityEvent, nowMs: Long = System.currentTimeMillis()) {
        if (consent.isPaused()) {
            conversationSeen.clear()
            return // ADR-0008 §3
        }
        val pkg = event.packageName?.toString() ?: return
        val appKey = MonitoredApps.appKeyFor(pkg) ?: return
        if (!rules.socialMonitoringEnabled(appKey)) {
            conversationSeen.forgetApp(appKey)
            return
        }
        synchronized(lock) {
            if (!SocialHeuristics.shouldCapture(lastCaptureAt[SocialHeuristics.debounceKey(appKey)], nowMs)) return
            lastCaptureAt[SocialHeuristics.debounceKey(appKey)] = nowMs
        }
        val texts = ArrayList<ConversationCapturePolicy.VisibleNode>()
        val root = event.source
        if (root != null) {
            try {
                collectVisibleText(root, StringBuilder(), texts)
            } finally {
                root.recycle()
            }
        }
        if (appKey == "whatsapp") {
            val conversation = ConversationCapturePolicy.parse(texts, packageId = pkg) ?: return
            if (!TestChatCaptureGate.allows(context, appKey, conversation.contact)) return
            for (capture in conversationSeen.newCaptures(appKey, conversation, packageId = pkg)) {
                val redacted = TextRedaction.redact(capture.text)
                queue.enqueue(
                    appKey,
                    capture.contact,
                    redacted,
                    occurrenceId = capture.occurrenceId,
                )
            }
            return
        }
        val (contact, message) = SocialHeuristics.extractContactAndMessage(texts.mapNotNull { it.text })
        val redacted = message?.let { TextRedaction.redact(it) } ?: return
        if (!TestChatCaptureGate.allows(context, appKey, contact)) return
        queue.enqueue(appKey, contact, redacted)
    }

    /** Depth-first collection of visible text/content-desc, stopping at [MAX_CAPTURE_CHARS]. */
    internal fun collectVisibleText(node: AccessibilityNodeInfo?, budget: StringBuilder, out: MutableList<ConversationCapturePolicy.VisibleNode>) {
        if (node == null || !node.isVisibleToUser || budget.length >= MAX_CAPTURE_CHARS) return
        val text = node.text?.toString() ?: node.contentDescription?.toString()
        if (!text.isNullOrBlank() || ConversationCapturePolicy.isStructuralMarker(node.viewIdResourceName.orEmpty())) {
            out.add(
                ConversationCapturePolicy.VisibleNode(
                    text = text,
                    viewIdResourceName = node.viewIdResourceName.orEmpty(),
                    className = node.className?.toString().orEmpty(),
                    isEditable = node.isEditable,
                    isFocused = node.isFocused,
                    parentViewIdResourceName = node.parent?.viewIdResourceName.orEmpty(),
                ),
            )
            budget.append(text).append('\n')
        }
        for (i in 0 until node.childCount) {
            val child = node.getChild(i)
            collectVisibleText(child, budget, out)
            child?.recycle()
            if (budget.length >= MAX_CAPTURE_CHARS) return
        }
    }

    fun onMonitoringPaused() = conversationSeen.clear()

    companion object {
        /** Max characters collected from the node tree per accessibility event. */
        const val MAX_CAPTURE_CHARS: Int = 4000
    }
}
