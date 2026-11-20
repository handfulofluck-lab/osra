package com.familyshield.agent.content

import android.view.accessibility.AccessibilityEvent
import android.view.accessibility.AccessibilityNodeInfo
import javax.inject.Inject
import javax.inject.Singleton

/**
 * ADR-0039: Play-flavor no-op implementation of [SearchCapture]. Keeps Play build free of
 * search-query collection until Play Data Safety and ADR amendment allow it.
 */
@Singleton
class NoopSearchCapture @Inject constructor() : SearchCapture {
    override fun onAccessibilityEvent(
        event: AccessibilityEvent,
        foregroundPackage: String?,
        activeRootProvider: (() -> AccessibilityNodeInfo?)?,
        nowMs: Long,
    ) = Unit
}
