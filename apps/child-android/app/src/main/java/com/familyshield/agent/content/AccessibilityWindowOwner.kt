package com.familyshield.agent.content

import android.view.accessibility.AccessibilityNodeInfo

/**
 * Pure abstraction over a readable accessibility node tree so ownership verification and
 * capture logic execute identically against real Android nodes and synthetic JVM fixtures
 * (`osra-security#44`).
 */
interface ReadableNode {
    val packageName: String?
    val text: CharSequence?
    val contentDescription: CharSequence?
    val viewIdResourceName: String?
    val className: CharSequence?
    val isEditable: Boolean
    val isFocused: Boolean
    val isVisibleToUser: Boolean
    val childCount: Int
    fun getChild(index: Int): ReadableNode?
    fun recycle() {}
}

/**
 * Verifies accessibility window ownership before any text or child nodes are read (`osra-security#44`).
 * Collection is declined whenever the expected monitored package is blank, the active root is missing,
 * or any input source (`activeRoot`, `eventPackage`, `eventSource`) has an unknown or mismatched owner.
 */
object WindowOwnershipPolicy {
    fun isOwnedByExpectedPackage(
        expectedPackage: String?,
        activeRoot: ReadableNode?,
        eventPackage: String?,
        eventSource: ReadableNode? = null,
    ): Boolean {
        val expected = expectedPackage?.takeIf { it.isNotBlank() } ?: return false
        if (activeRoot == null) return false
        if (activeRoot.packageName != expected) return false
        if (eventPackage != expected) return false
        if (eventSource != null && eventSource.packageName != expected) return false
        return true
    }

    /**
     * Selects the verified root node only when [expectedPackage] is eligible, [eventPackage] matches it,
     * and every supplied node source (`activeRoot`, `eventSource`) is owned by [expectedPackage].
     * Never falls back to `eventSource` when `activeRoot` is present with a mismatched owner.
     */
    fun selectVerifiedRoot(
        expectedPackage: String?,
        eventPackage: String?,
        isPackageEligible: (String) -> Boolean,
        activeRoot: ReadableNode?,
        eventSource: ReadableNode? = null,
    ): ReadableNode? {
        val pkg = expectedPackage?.takeIf { it.isNotBlank() && isPackageEligible(it) } ?: return null
        if (eventPackage != pkg) return null
        val candidate = when {
            activeRoot != null -> activeRoot
            eventSource != null -> eventSource
            else -> return null
        }
        if (candidate.packageName != pkg) return null
        if (eventSource != null && eventSource !== candidate && eventSource.packageName != pkg) return null
        return candidate
    }
}

/** Platform wrapper delegating [ReadableNode] access to a live Android [AccessibilityNodeInfo]. */
internal class PlatformReadableNode(private val node: AccessibilityNodeInfo) : ReadableNode {
    override val packageName: String? get() = node.packageName?.toString()
    override val text: CharSequence? get() = node.text
    override val contentDescription: CharSequence? get() = node.contentDescription
    override val viewIdResourceName: String? get() = node.viewIdResourceName
    override val className: CharSequence? get() = node.className
    override val isEditable: Boolean get() = node.isEditable
    override val isFocused: Boolean get() = node.isFocused
    override val isVisibleToUser: Boolean get() = node.isVisibleToUser
    override val childCount: Int get() = node.childCount
    override fun getChild(index: Int): ReadableNode? = node.getChild(index)?.let(::PlatformReadableNode)
    override fun recycle() {
        node.recycle()
    }
}
