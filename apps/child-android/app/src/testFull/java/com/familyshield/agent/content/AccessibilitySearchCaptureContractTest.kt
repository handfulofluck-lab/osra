package com.familyshield.agent.content

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Full-flavor behavioral tests for [AccessibilitySearchCapture] covering:
 * - `osra-security#44`: verified window ownership before inspecting any nodes
 * - `osra-security#45`: disabled/revoked opt-in, submitted-only queries, durable queue handoff.
 */
class AccessibilitySearchCaptureContractTest {

    private class SpyNode(
        override val packageName: String?,
        private val rawText: CharSequence? = null,
        private val children: List<SpyNode> = emptyList(),
        override val viewIdResourceName: String? = null,
        override val className: CharSequence? = "android.widget.TextView",
        override val isEditable: Boolean = false,
        override val isFocused: Boolean = false,
        private val visibleToUser: Boolean = true,
    ) : ReadableNode {
        var reads: Int = 0
            private set

        override val isVisibleToUser: Boolean
            get() {
                reads++
                return visibleToUser
            }

        override val text: CharSequence?
            get() {
                reads++
                return rawText
            }

        override val contentDescription: CharSequence?
            get() {
                reads++
                return null
            }

        override val childCount: Int
            get() {
                reads++
                return children.size
            }

        override fun getChild(index: Int): ReadableNode? {
            reads++
            return children.getOrNull(index)
        }

        fun totalReads(): Int = reads + children.sumOf { it.totalReads() }
    }

    private fun chromeResultsTree(ownerPkg: String?, focusedUrlBar: Boolean = false): SpyNode = SpyNode(
        packageName = ownerPkg,
        children = listOf(
            SpyNode(
                ownerPkg,
                rawText = "https://www.google.com/search?q=chemistry+homework",
                viewIdResourceName = "com.android.chrome:id/url_bar",
                isEditable = focusedUrlBar,
                isFocused = focusedUrlBar,
            ),
            SpyNode(ownerPkg, rawText = "chemistry homework - Google Search"),
            SpyNode(ownerPkg, rawText = "Result 1"),
            SpyNode(ownerPkg, rawText = "Result 2"),
        ),
    )

    @Test
    fun `disabled or revoked opt-in never touches accessibility root or enqueues queries`() {
        var optIn = false
        var rootInvoked = false
        val enqueued = mutableListOf<Pair<String, String>>()
        val capture = AccessibilitySearchCapture(
            rules = null,
            consent = null,
            isPausedProvider = { false },
            searchMonitoringEnabledProvider = { optIn },
            enqueueSearch = { engine, query, _ -> enqueued.add(engine to query) },
        )

        assertFalse(
            capture.captureFromWindow(
                foregroundPackage = "com.android.chrome",
                eventPackage = "com.android.chrome",
                activeRootProvider = {
                    rootInvoked = true
                    chromeResultsTree("com.android.chrome")
                },
                nowMs = 5_000L,
            ),
        )
        assertFalse(rootInvoked)
        assertTrue(enqueued.isEmpty())

        // Enable, capture once, then revoke.
        optIn = true
        assertTrue(
            capture.captureFromWindow(
                foregroundPackage = "com.android.chrome",
                eventPackage = "com.android.chrome",
                activeRootProvider = { chromeResultsTree("com.android.chrome") },
                nowMs = 10_000L,
            ),
        )
        assertEquals(listOf("google" to "chemistry homework"), enqueued)

        optIn = false
        assertFalse(
            capture.captureFromWindow(
                foregroundPackage = "com.google.android.youtube",
                eventPackage = "com.google.android.youtube",
                activeRootProvider = {
                    rootInvoked = true
                    chromeResultsTree("com.google.android.youtube")
                },
                nowMs = 20_000L,
            ),
        )
        assertFalse(rootInvoked)
        assertEquals(1, enqueued.size)
    }

    @Test
    fun `window ownership declines missing or different owners without reading nodes and skips unfocused typing`() {
        val enqueued = mutableListOf<Pair<String, String>>()
        val capture = AccessibilitySearchCapture(
            rules = null,
            consent = null,
            isPausedProvider = { false },
            searchMonitoringEnabledProvider = { true },
            enqueueSearch = { engine, query, _ -> enqueued.add(engine to query) },
        )

        val unknownOwner = chromeResultsTree(ownerPkg = null)
        assertFalse(
            capture.captureFromWindow(
                foregroundPackage = "com.android.chrome",
                eventPackage = "com.android.chrome",
                activeRootProvider = { unknownOwner },
                nowMs = 1_000L,
            ),
        )
        assertEquals(0, unknownOwner.totalReads())

        val otherRoot = chromeResultsTree(ownerPkg = "com.bank.app")
        val matchingSource = chromeResultsTree(ownerPkg = "com.android.chrome")
        assertFalse(
            capture.captureFromWindow(
                foregroundPackage = "com.android.chrome",
                eventPackage = "com.android.chrome",
                activeRootProvider = { otherRoot },
                eventSourceProvider = { matchingSource },
                nowMs = 2_000L,
            ),
        )
        assertEquals(0, otherRoot.totalReads())
        assertEquals(0, matchingSource.totalReads())

        val validRootWrongEvent = chromeResultsTree(ownerPkg = "com.android.chrome")
        assertFalse(
            capture.captureFromWindow(
                foregroundPackage = "com.android.chrome",
                eventPackage = "com.android.systemui",
                activeRootProvider = { validRootWrongEvent },
                nowMs = 3_000L,
            ),
        )
        assertEquals(0, validRootWrongEvent.totalReads())
        assertTrue(enqueued.isEmpty())

        // In-progress typing inside a focused search box without SERP submission produces zero enqueues.
        val focusedTypingTree = SpyNode(
            packageName = "com.android.chrome",
            children = listOf(
                SpyNode("com.android.chrome", rawText = "chem", isEditable = true, isFocused = true, viewIdResourceName = "com.android.chrome:id/url_bar"),
                SpyNode("com.android.chrome", rawText = "Bookmarks"),
                SpyNode("com.android.chrome", rawText = "History"),
                SpyNode("com.android.chrome", rawText = "Downloads"),
            ),
        )
        assertFalse(
            capture.captureFromWindow(
                foregroundPackage = "com.android.chrome",
                eventPackage = "com.android.chrome",
                activeRootProvider = { focusedTypingTree },
                nowMs = 4_000L,
            ),
        )
        assertTrue(enqueued.isEmpty())

        // Mixed-window descendant regression + lazy eventSource acquisition after early-exit checks.
        var sourceAcquiredOnMismatch = false
        assertFalse(
            capture.captureFromWindow(
                foregroundPackage = "com.android.chrome",
                eventPackage = "com.android.systemui",
                activeRootProvider = { chromeResultsTree("com.android.chrome") },
                eventSourceProvider = {
                    sourceAcquiredOnMismatch = true
                    chromeResultsTree("com.android.chrome")
                },
                nowMs = 10_000L,
            ),
        )
        assertFalse(sourceAcquiredOnMismatch)

        val foreignOverlayNode = SpyNode("com.android.autofill", rawText = "https://www.google.com/search?q=stolen+query")
        val unknownDescendantNode = SpyNode(null, rawText = "private overlay")
        val mixedChromeRoot = SpyNode(
            packageName = "com.android.chrome",
            children = listOf(
                foreignOverlayNode,
                unknownDescendantNode,
                SpyNode("com.android.chrome", rawText = "physics revision - Google Search"),
            ),
        )
        assertTrue(
            capture.captureFromWindow(
                foregroundPackage = "com.android.chrome",
                eventPackage = "com.android.chrome",
                activeRootProvider = { mixedChromeRoot },
                nowMs = 20_000L,
            ),
        )
        assertEquals(0, foreignOverlayNode.totalReads())
        assertEquals(0, unknownDescendantNode.totalReads())
        assertEquals(listOf("google" to "physics revision"), enqueued)
    }
}
