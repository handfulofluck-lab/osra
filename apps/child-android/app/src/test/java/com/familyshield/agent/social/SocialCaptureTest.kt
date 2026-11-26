package com.familyshield.agent.social

import android.content.Context
import android.view.accessibility.AccessibilityNodeInfo
import com.familyshield.agent.data.ConsentState
import com.familyshield.agent.data.RuleRepository
import java.io.File
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import org.mockito.Mockito

class SocialCaptureTest {
    private fun node(
        text: String?,
        id: String,
        className: String = "android.widget.TextView",
        editable: Boolean = false,
        focused: Boolean = false,
        children: List<AccessibilityNodeInfo> = emptyList(),
    ): AccessibilityNodeInfo = Mockito.mock(AccessibilityNodeInfo::class.java).apply {
        Mockito.`when`(viewIdResourceName).thenReturn(id)
        Mockito.`when`(this.text).thenReturn(text)
        Mockito.`when`(contentDescription).thenReturn(null)
        Mockito.`when`(this.className).thenReturn(className)
        Mockito.`when`(isVisibleToUser).thenReturn(true)
        Mockito.`when`(isEditable).thenReturn(editable)
        Mockito.`when`(isFocused).thenReturn(focused)
        Mockito.`when`(childCount).thenReturn(children.size)
        children.forEachIndexed { index, child ->
            Mockito.`when`(getChild(index)).thenReturn(child)
            Mockito.`when`(child.parent).thenReturn(this)
        }
    }

    private fun capture(): SocialCapture = SocialCapture(
        Mockito.mock(RuleRepository::class.java),
        Mockito.mock(SocialScanQueue::class.java),
        Mockito.mock(ConsentState::class.java),
        Mockito.mock(Context::class.java),
    )

    @Test
    fun `actual collection keeps textless row markers and verifies message ancestry`() {
        val root = node(null, "com.whatsapp:id/conversation_text_row", children = listOf(
            node("Alex", "com.whatsapp:id/conversation_contact_name"),
            node("real bubble", "com.whatsapp:id/message_text"),
            node("unrelated label", "com.whatsapp:id/other"),
        ))
        val out = mutableListOf<ConversationCapturePolicy.VisibleNode>()

        capture().collectVisibleText(root, StringBuilder(), out)
        val conversation = ConversationCapturePolicy.parse(out)

        assertEquals(listOf("real bubble"), conversation?.messages)
    }

    @Test
    fun `actual collection excludes compose draft and wrong parent while keeping valid sibling`() {
        val root = node(null, "com.whatsapp:id/root", children = listOf(
            node("Alex", "com.whatsapp:id/conversation_contact_name"),
            node(null, "com.whatsapp:id/conversation_text_row", children = listOf(
                node("valid sibling", "com.whatsapp:id/message_text"),
            )),
            node(null, "com.whatsapp:id/other_row", children = listOf(
                node("wrong parent", "com.whatsapp:id/message_text"),
            )),
            node("unsent draft", "com.whatsapp:id/entry", "android.widget.EditText", editable = true, focused = true),
        ))
        val out = mutableListOf<ConversationCapturePolicy.VisibleNode>()

        capture().collectVisibleText(root, StringBuilder(), out)

        assertEquals(listOf("valid sibling"), ConversationCapturePolicy.parse(out)?.messages)
    }

    private fun fire(
        capture: SocialCapture,
        packageId: String,
        root: AccessibilityNodeInfo,
        nowMs: Long = 1_000L,
    ) {
        val event = Mockito.mock(android.view.accessibility.AccessibilityEvent::class.java)
        Mockito.`when`(event.packageName).thenReturn(packageId)
        Mockito.`when`(event.source).thenReturn(root)
        capture.onAccessibilityEvent(event, nowMs)
    }

    private fun realConsent(): ConsentState {
        val settings = Mockito.mock(com.familyshield.agent.data.AgentSettings::class.java)
        val context = Mockito.mock(Context::class.java)
        val prefs = Mockito.mock(android.content.SharedPreferences::class.java)
        Mockito.`when`(prefs.contains(Mockito.anyString())).thenReturn(false)
        Mockito.`when`(context.getSharedPreferences(Mockito.anyString(), Mockito.anyInt())).thenReturn(prefs)
        return ConsentState(settings, context)
    }

    @Test
    fun `production entry point captures business package with business resource ids`() {
        val queue = Mockito.mock(SocialScanQueue::class.java)
        val rules = Mockito.mock(RuleRepository::class.java)
        Mockito.`when`(rules.socialMonitoringEnabled("whatsapp")).thenReturn(true)
        val context = Mockito.mock(Context::class.java)
        Mockito.`when`(context.filesDir).thenReturn(File(System.getProperty("java.io.tmpdir")))
        val capture = SocialCapture(rules, queue, realConsent(), context)
        val root = node(null, "com.whatsapp.w4b:id/conversation_text_row", children = listOf(
            node("Alex", "com.whatsapp.w4b:id/conversation_contact_name"),
            node("business bubble", "com.whatsapp.w4b:id/message_text"),
        ))

        fire(capture, "com.whatsapp.w4b", root)

        val invocation = Mockito.mockingDetails(queue).invocations.single()
        val args = invocation.arguments
        assertEquals("whatsapp", args[0])
        assertEquals("Alex", args[1])
        assertEquals("business bubble", args[2])
    }

    @Test
    fun `consent withdrawal clears capture state before any subsequent chat event`() {
        val queue = Mockito.mock(SocialScanQueue::class.java)
        val rules = Mockito.mock(RuleRepository::class.java)
        Mockito.`when`(rules.socialMonitoringEnabled("whatsapp")).thenReturn(true)
        val context = Mockito.mock(Context::class.java)
        Mockito.`when`(context.filesDir).thenReturn(File(System.getProperty("java.io.tmpdir")))
        val consent = realConsent()
        val capture = SocialCapture(rules, queue, consent, context)
        fire(capture, "com.whatsapp", node(null, "com.whatsapp:id/conversation_text_row", children = listOf(
            node("Alex", "com.whatsapp:id/conversation_contact_name"),
            node("repeat", "com.whatsapp:id/message_text"),
        )))

        Mockito.mockStatic(android.util.Log::class.java).use { ignored ->
            consent.onCommand(com.familyshield.agent.data.ConsentPolicy.COMMAND_REVOKED)
            consent.onCommand(com.familyshield.agent.data.ConsentPolicy.COMMAND_GRANTED)
        }
        val secondRoot = node(null, "com.whatsapp:id/conversation_text_row", children = listOf(
            node("Alex", "com.whatsapp:id/conversation_contact_name"),
            node("repeat", "com.whatsapp:id/message_text"),
        ))
        fire(capture, "com.whatsapp", secondRoot, 3_000L)

        assertEquals(2, Mockito.mockingDetails(queue).invocations.size)
    }

    @Test
    fun `app opt out clears capture state before any subsequent chat event`() {
        val tracker = ConversationCapturePolicy.SeenTracker()
        tracker.newCaptures("whatsapp", listOf(
            ConversationCapturePolicy.VisibleNode("Alex", "com.whatsapp:id/conversation_contact_name", "android.widget.TextView", false, false),
            ConversationCapturePolicy.VisibleNode(null, "com.whatsapp:id/conversation_text_row", "android.widget.FrameLayout", false, false),
            ConversationCapturePolicy.VisibleNode("repeat", "com.whatsapp:id/message_text", "android.widget.TextView", false, false, "com.whatsapp:id/conversation_text_row"),
        ))

        tracker.retainOnly { false }

        assertEquals(0, tracker.trackedConversations)
        assertEquals(1, tracker.newCaptures("whatsapp", listOf(
            ConversationCapturePolicy.VisibleNode("Alex", "com.whatsapp:id/conversation_contact_name", "android.widget.TextView", false, false),
            ConversationCapturePolicy.VisibleNode(null, "com.whatsapp:id/conversation_text_row", "android.widget.FrameLayout", false, false),
            ConversationCapturePolicy.VisibleNode("repeat", "com.whatsapp:id/message_text", "android.widget.TextView", false, false, "com.whatsapp:id/conversation_text_row"),
        )).size)
        val source = File("src/main/java/com/familyshield/agent/social/SocialCapture.kt").readText()
        assertTrue(source.contains("addRulesChangedListener"))
        assertTrue(source.contains("retainOnly"))
    }

    @Test
    fun `paused service path clears occurrence state without another chat event`() {
        val source = File("src/main/java/com/familyshield/agent/services/AccessibilityMonitorService.kt").readText()
        val pausedBlock = source.substringAfter("if (consentState.isPaused()) {", "")

        assertTrue(pausedBlock.contains("social.onMonitoringPaused()"))
        assertTrue(pausedBlock.indexOf("social.onMonitoringPaused()") < pausedBlock.indexOf("return"))
    }
}
