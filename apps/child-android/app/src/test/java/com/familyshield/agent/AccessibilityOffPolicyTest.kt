package com.familyshield.agent

import com.familyshield.agent.receivers.AccessibilityOffPolicy
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Pure-JVM tests for Feature #19 accessibility-disabled parsing: our component present/absent in
 * ENABLED_ACCESSIBILITY_SERVICES (incl. multi-colon flattened names), and the effective-enabled /
 * tamper-state decisions on top of ACCESSIBILITY_ENABLED.
 */
class AccessibilityOffPolicyTest {

    private val component = "com.familyshield.agent/com.familyshield.agent.services.AccessibilityMonitorService"

    @Test
    fun `our service alone is enabled`() {
        assertTrue(AccessibilityOffPolicy.isServiceEnabled(component, component))
    }

    @Test
    fun `our service present among others is enabled`() {
        val services = "com.android.talkback/com.android.talkback.TalkBackService:$component"
        assertTrue(AccessibilityOffPolicy.isServiceEnabled(services, component))
    }

    @Test
    fun `our service absent is not enabled`() {
        val services = "com.android.talkback/com.android.talkback.TalkBackService:com.example.other/com.example.other.Svc"
        assertFalse(AccessibilityOffPolicy.isServiceEnabled(services, component))
    }

    @Test
    fun `multi-colon entries do not confuse the parser`() {
        // A TalkBack-style entry with a colon suffix plus a second multi-segment id.
        val services = "com.android.talkback/com.android.talkback.TalkBackService:com.google.android.marvin.talkback:8"
        assertFalse(AccessibilityOffPolicy.isServiceEnabled(services, component))
        assertTrue(
            AccessibilityOffPolicy.isServiceEnabled(
                "$services:$component",
                component,
            ),
        )
    }

    @Test
    fun `our component with a colon suffix variant still matches`() {
        assertTrue(AccessibilityOffPolicy.isServiceEnabled("$component:main", component))
    }

    @Test
    fun `same class name in another package is not a match`() {
        val impostor = "com.familyshield.agent.evil/com.familyshield.agent.services.AccessibilityMonitorService"
        assertFalse(AccessibilityOffPolicy.isServiceEnabled(impostor, component))
        // And the substring of our class alone must not match either.
        assertFalse(AccessibilityOffPolicy.isServiceEnabled("com.x/com.y.AccessibilityMonitorService", component))
    }

    @Test
    fun `blank or missing enabled services is not enabled`() {
        assertFalse(AccessibilityOffPolicy.isServiceEnabled(null, component))
        assertFalse(AccessibilityOffPolicy.isServiceEnabled("", component))
        assertFalse(AccessibilityOffPolicy.isServiceEnabled("   ", component))
    }

    @Test
    fun `effectively enabled requires global switch on and our service listed`() {
        assertTrue(AccessibilityOffPolicy.isEffectivelyEnabled("1", component, component))
        assertFalse(AccessibilityOffPolicy.isEffectivelyEnabled("0", component, component))
        assertFalse(AccessibilityOffPolicy.isEffectivelyEnabled("1", null, component))
        assertFalse(AccessibilityOffPolicy.isEffectivelyEnabled(null, component, component))
    }

    @Test
    fun `tamper state is the inverse of effectively enabled`() {
        assertFalse(AccessibilityOffPolicy.isTamperState("1", component, component))
        assertTrue(AccessibilityOffPolicy.isTamperState("0", component, component))
        assertTrue(AccessibilityOffPolicy.isTamperState("1", null, component))
        assertTrue(AccessibilityOffPolicy.isTamperState(null, null, component))
    }
}
