package com.familyshield.agent.content

import com.familyshield.agent.social.SocialCapture
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Synthetic accessibility fixture tests for `osra-security#44`:
 * verifies window ownership against the enabled monitored package before any text or child node
 * is inspected in `SocialCapture`.
 */
class WindowOwnershipCaptureTest {

    private class SpyReadableNode(
        override val packageName: String?,
        private val rawText: CharSequence? = null,
        private val rawContentDesc: CharSequence? = null,
        private val children: List<SpyReadableNode> = emptyList(),
        override val viewIdResourceName: String? = null,
        override val className: CharSequence? = "android.widget.TextView",
        override val isEditable: Boolean = false,
        override val isFocused: Boolean = false,
        override val isVisibleToUser: Boolean = true,
    ) : ReadableNode {
        var textReads: Int = 0
            private set
        var childReads: Int = 0
            private set

        override val text: CharSequence?
            get() {
                textReads++
                return rawText
            }

        override val contentDescription: CharSequence?
            get() {
                textReads++
                return rawContentDesc
            }

        override val childCount: Int
            get() {
                childReads++
                return children.size
            }

        override fun getChild(index: Int): ReadableNode? {
            childReads++
            return children.getOrNull(index)
        }

        fun totalInspectionCount(): Int = textReads + childReads + children.sumOf { it.totalInspectionCount() }
    }

    private fun monitoredChatTree(rootPkg: String?): SpyReadableNode = SpyReadableNode(
        packageName = rootPkg,
        children = listOf(
            SpyReadableNode(rootPkg, rawText = "Alex"),
            SpyReadableNode(rootPkg, rawText = "meet me alone at 9pm tonight and do not tell mom"),
        ),
    )

    @Test
    fun `matching owner reads nodes and enqueues redacted social message`() {
        val enqueued = mutableListOf<Triple<String, String?, String>>()
        val capture = SocialCapture(
            isPausedProvider = { false },
            socialMonitoringProvider = { it == "whatsapp" },
            enqueueCapture = { appKey, contact, text, _ -> enqueued.add(Triple(appKey, contact, text)) },
        )
        val root = monitoredChatTree("com.whatsapp")
        val source = SpyReadableNode(packageName = "com.whatsapp")

        val captured = capture.captureFromWindow(
            foregroundPackage = "com.whatsapp",
            eventPackage = "com.whatsapp",
            activeRootProvider = { root },
            eventSourceProvider = { source },
            nowMs = 10_000L,
        )

        assertTrue(captured)
        assertTrue("matching owner should inspect text", root.totalInspectionCount() > 0)
        assertEquals(1, enqueued.size)
        assertEquals("whatsapp", enqueued[0].first)
    }

    @Test
    fun `missing owner declines collection with zero text reads or queued items`() {
        val enqueued = mutableListOf<Triple<String, String?, String>>()
        val capture = SocialCapture(
            isPausedProvider = { false },
            socialMonitoringProvider = { true },
            enqueueCapture = { appKey, contact, text, _ -> enqueued.add(Triple(appKey, contact, text)) },
        )
        val unknownRoot = monitoredChatTree(rootPkg = null)

        assertFalse(
            capture.captureFromWindow(
                foregroundPackage = "com.whatsapp",
                eventPackage = "com.whatsapp",
                activeRootProvider = { unknownRoot },
                nowMs = 10_000L,
            ),
        )
        assertEquals("missing root owner must not read any node text or children", 0, unknownRoot.totalInspectionCount())
        assertTrue(enqueued.isEmpty())

        // Missing eventPackage also declines without touching the root tree.
        val validRoot = monitoredChatTree("com.whatsapp")
        assertFalse(
            capture.captureFromWindow(
                foregroundPackage = "com.whatsapp",
                eventPackage = null,
                activeRootProvider = { validRoot },
                nowMs = 20_000L,
            ),
        )
        assertEquals(0, validRoot.totalInspectionCount())
        assertTrue(enqueued.isEmpty())
    }

    @Test
    fun `different owner across activeRoot, eventPackage, or eventSource declines collection with zero reads`() {
        val enqueued = mutableListOf<Triple<String, String?, String>>()
        val capture = SocialCapture(
            isPausedProvider = { false },
            socialMonitoringProvider = { true },
            enqueueCapture = { appKey, contact, text, _ -> enqueued.add(Triple(appKey, contact, text)) },
        )

        // Mismatched activeRoot + matching fallback eventSource: must reject and read nothing.
        val otherRoot = monitoredChatTree("com.android.settings")
        val matchingSource = monitoredChatTree("com.whatsapp")
        assertFalse(
            capture.captureFromWindow(
                foregroundPackage = "com.whatsapp",
                eventPackage = "com.whatsapp",
                activeRootProvider = { otherRoot },
                eventSourceProvider = { matchingSource },
                nowMs = 10_000L,
            ),
        )
        assertEquals(0, otherRoot.totalInspectionCount())
        assertEquals(0, matchingSource.totalInspectionCount())

        // Mismatched eventPackage while activeRoot is WhatsApp.
        val whatsappRoot = monitoredChatTree("com.whatsapp")
        assertFalse(
            capture.captureFromWindow(
                foregroundPackage = "com.whatsapp",
                eventPackage = "com.android.systemui",
                activeRootProvider = { whatsappRoot },
                nowMs = 20_000L,
            ),
        )
        assertEquals(0, whatsappRoot.totalInspectionCount())

        // Disabled monitored app skips activeRootProvider altogether.
        var rootInvoked = false
        val disabledCapture = SocialCapture(
            isPausedProvider = { false },
            socialMonitoringProvider = { false },
            enqueueCapture = { appKey, contact, text, _ -> enqueued.add(Triple(appKey, contact, text)) },
        )
        assertFalse(
            disabledCapture.captureFromWindow(
                foregroundPackage = "com.whatsapp",
                eventPackage = "com.whatsapp",
                activeRootProvider = {
                    rootInvoked = true
                    monitoredChatTree("com.whatsapp")
                },
                nowMs = 30_000L,
            ),
        )
        assertFalse(rootInvoked)
        assertTrue(enqueued.isEmpty())
    }
}
