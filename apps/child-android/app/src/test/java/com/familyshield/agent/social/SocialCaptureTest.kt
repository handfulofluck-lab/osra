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
    fun `consent withdrawal during admission clears state before the next capture`() {
        val queue = Mockito.mock(SocialScanQueue::class.java)
        val rules = Mockito.mock(RuleRepository::class.java)
        Mockito.`when`(rules.socialMonitoringEnabled("whatsapp")).thenReturn(true)
        val context = Mockito.mock(Context::class.java)
        val consent = realConsent()
        val capture = SocialCapture(rules, queue, consent, context)
        val entered = java.util.concurrent.CountDownLatch(1)
        val release = java.util.concurrent.CountDownLatch(1)
        Mockito.doAnswer {
            entered.countDown()
            release.await(5, java.util.concurrent.TimeUnit.SECONDS)
            File(System.getProperty("java.io.tmpdir"))
        }.`when`(context).filesDir
        val root = node(null, "com.whatsapp:id/conversation_text_row", children = listOf(
            node("Alex", "com.whatsapp:id/conversation_contact_name"),
            node("repeat", "com.whatsapp:id/message_text"),
        ))

        Mockito.mockStatic(android.util.Log::class.java).use { ignored ->
            val first = Thread { fire(capture, "com.whatsapp", root) }
            first.start()
            assertTrue(entered.await(5, java.util.concurrent.TimeUnit.SECONDS))
            val releaser = Thread {
                while (!consent.isPaused()) Thread.sleep(1)
                release.countDown()
            }
            releaser.start()
            consent.onCommand(com.familyshield.agent.data.ConsentPolicy.COMMAND_REVOKED)
            first.join(5_000)
            releaser.join(5_000)
            assertTrue(!first.isAlive)
            assertTrue(!releaser.isAlive)
            consent.onCommand(com.familyshield.agent.data.ConsentPolicy.COMMAND_GRANTED)
            fire(capture, "com.whatsapp", root, 3_000L)
        }

        assertEquals(2, Mockito.mockingDetails(queue).invocations.size)
    }

    @Test
    fun `app opt out during admission clears state before the next capture`() {
        val queue = Mockito.mock(SocialScanQueue::class.java)
        val rules = Mockito.mock(RuleRepository::class.java)
        val enabled = java.util.concurrent.atomic.AtomicBoolean(true)
        Mockito.`when`(rules.socialMonitoringEnabled("whatsapp")).thenAnswer { enabled.get() }
        var appliedListener: (() -> Unit)? = null
        Mockito.doAnswer { invocation ->
            appliedListener = invocation.arguments[0] as () -> Unit
            null
        }.`when`(rules).addRulesAppliedListener(Mockito.any<() -> Unit>() ?: {})
        val context = Mockito.mock(Context::class.java)
        val capture = SocialCapture(rules, queue, realConsent(), context)
        val entered = java.util.concurrent.CountDownLatch(1)
        val release = java.util.concurrent.CountDownLatch(1)
        Mockito.doAnswer {
            entered.countDown()
            release.await(5, java.util.concurrent.TimeUnit.SECONDS)
            File(System.getProperty("java.io.tmpdir"))
        }.`when`(context).filesDir
        val root = node(null, "com.whatsapp:id/conversation_text_row", children = listOf(
            node("Alex", "com.whatsapp:id/conversation_contact_name"),
            node("repeat", "com.whatsapp:id/message_text"),
        ))

        val first = Thread { fire(capture, "com.whatsapp", root) }
        first.start()
        assertTrue(entered.await(5, java.util.concurrent.TimeUnit.SECONDS))
        val releaser = Thread {
            while (enabled.get()) Thread.sleep(1)
            release.countDown()
        }
        releaser.start()
        enabled.set(false)
        appliedListener!!()
        first.join(5_000)
        releaser.join(5_000)
        assertTrue(!first.isAlive)
        assertTrue(!releaser.isAlive)
        enabled.set(true)
        fire(capture, "com.whatsapp", root, 3_000L)

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
        assertTrue(source.contains("addRulesAppliedListener"))
        assertTrue(source.contains("retainOnly"))
        val repository = File("src/main/java/com/familyshield/agent/data/RuleRepository.kt").readText()
        val applied = repository.indexOf("cached = updated")
        val immediate = repository.indexOf("rulesAppliedListeners.forEach")
        val categoryPack = repository.indexOf("blocklist.refresh(updated.webFilter.blockedCategories)")
        val persisted = repository.indexOf("rulesChangedListeners.forEach")
        assertTrue(applied in 0 until immediate)
        assertTrue(immediate < categoryPack)
        assertTrue(categoryPack < persisted)
    }

    @Test
    fun `paused service path clears occurrence state without another chat event`() {
        val source = File("src/main/java/com/familyshield/agent/services/AccessibilityMonitorService.kt").readText()
        val pausedBlock = source.substringAfter("if (consentState.isPaused()) {", "")

        assertTrue(pausedBlock.contains("social.onMonitoringPaused()"))
        assertTrue(pausedBlock.indexOf("social.onMonitoringPaused()") < pausedBlock.indexOf("return"))
    }
}
