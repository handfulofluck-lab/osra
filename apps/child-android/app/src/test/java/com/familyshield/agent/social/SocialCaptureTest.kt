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
    fun `actual collection excludes compose draft and wrong parent`() {
        val root = node(null, "com.whatsapp:id/root", children = listOf(
            node(null, "com.whatsapp:id/conversation_text_row"),
            node("unsent draft", "com.whatsapp:id/entry", "android.widget.EditText", editable = true, focused = true),
            node("wrong parent", "com.whatsapp:id/message_text"),
        ))
        val out = mutableListOf<ConversationCapturePolicy.VisibleNode>()

        capture().collectVisibleText(root, StringBuilder(), out)

        assertEquals(null, ConversationCapturePolicy.parse(out))
    }

    @Test
    fun `paused service path clears occurrence state without another chat event`() {
        val source = File("src/main/java/com/familyshield/agent/services/AccessibilityMonitorService.kt").readText()
        val pausedBlock = source.substringAfter("if (consentState.isPaused()) {", "")

        assertTrue(pausedBlock.contains("social.onMonitoringPaused()"))
        assertTrue(pausedBlock.indexOf("social.onMonitoringPaused()") < pausedBlock.indexOf("return"))
    }
}
