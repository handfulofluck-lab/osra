package com.familyshield.agent.security

import com.familyshield.agent.receivers.AccessibilityOffPolicy
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Issue #225: `ENABLED_ACCESSIBILITY_SERVICES` may hold our component in either string form —
 * fully qualified or the short `pkg/.Class` form — and both must count as enabled. The parser must
 * also ignore other services/packages, tolerate a `:subId` suffix and malformed entries, and never
 * match a different class in our own package.
 */
class AccessibilityServiceListPolicyTest {

    private val packageName = "com.familyshield.agent"
    private val className = "com.familyshield.agent.services.AccessibilityMonitorService"
    private val fullyQualified = "$packageName/$className"
    private val shortForm = "$packageName/.services.AccessibilityMonitorService"

    @Test
    fun `fully qualified form matches`() {
        assertTrue(AccessibilityServiceListPolicy.isEnabled(fullyQualified, packageName, className))
        assertTrue(AccessibilityServiceListPolicy.isEnabled(fullyQualified, fullyQualified))
    }

    @Test
    fun `short form with a leading dot matches`() {
        assertTrue(AccessibilityServiceListPolicy.isEnabled(shortForm, packageName, className))
        assertTrue(AccessibilityServiceListPolicy.isEnabled(shortForm, fullyQualified))
    }

    // 2026-10-29 (decision 2B): package and namespace are now different things — the installed
    // applicationId is `com.osratech.child` while every class stays in `com.familyshield.agent`. The
    // accessibility gate is the surface that depends on the split, because the OS reports the
    // component as `<applicationId>/<class>`. Claude's R1 row.
    //
    // Mutant: make `fullyQualified` resolve a relative class against the *namespace* (or drop the
    // package half of the comparison) and the second assertion below flips to true — which is the
    // bug this row exists to stop, because `com.osratech.child/.services.X` names a class that
    // does not exist.
    @Test
    fun `the component is package-from-the-build and class-from-the-namespace`() {
        val installed = "com.osratech.child"
        val monitor = "com.familyshield.agent.services.AccessibilityMonitorService"

        assertTrue(
            "the OS form is applicationId/fully-qualified-class",
            AccessibilityServiceListPolicy.isEnabled("$installed/$monitor", installed, monitor),
        )
        assertFalse(
            "the old pkg/.Class shorthand cannot resolve once package and namespace differ",
            AccessibilityServiceListPolicy.isEnabled(
                "$installed/.services.AccessibilityMonitorService",
                installed,
                monitor,
            ),
        )
    }

    @Test
    fun `our service is found among other services and packages`() {
        val services = "com.android.talkback/.TalkBackService:$shortForm:com.example.other/.OtherService"
        assertTrue(AccessibilityServiceListPolicy.isEnabled(services, packageName, className))
        assertTrue(
            AccessibilityServiceListPolicy.isEnabled(
                "$fullyQualified:com.example.other/.OtherService",
                packageName,
                className,
            ),
        )
    }

    @Test
    fun `a subId suffix on our entry does not prevent a match`() {
        assertTrue(AccessibilityServiceListPolicy.isEnabled("$shortForm:main", packageName, className))
        assertTrue(AccessibilityServiceListPolicy.isEnabled("$fullyQualified:42", packageName, className))
        assertTrue(AccessibilityServiceListPolicy.isEnabled("com.example.other/.Other:$fullyQualified:7", packageName, className))
    }

    @Test
    fun `null blank or empty list is not enabled`() {
        assertFalse(AccessibilityServiceListPolicy.isEnabled(null, packageName, className))
        assertFalse(AccessibilityServiceListPolicy.isEnabled("", packageName, className))
        assertFalse(AccessibilityServiceListPolicy.isEnabled("   ", packageName, className))
    }

    @Test
    fun `a different class in our own package does not match`() {
        assertFalse(
            AccessibilityServiceListPolicy.isEnabled(
                "$packageName/.services.OtherService",
                packageName,
                className,
            ),
        )
        assertFalse(
            AccessibilityServiceListPolicy.isEnabled(
                "$packageName/$packageName.services.OtherService",
                packageName,
                className,
            ),
        )
    }

    @Test
    fun `the same class in another package does not match`() {
        assertFalse(
            AccessibilityServiceListPolicy.isEnabled(
                "com.example.impostor/$className",
                packageName,
                className,
            ),
        )
    }

    @Test
    fun `malformed entries are ignored rather than matched`() {
        val services = "garbage:/NoPackage:$packageName/:com.example.other.None"
        assertFalse(AccessibilityServiceListPolicy.isEnabled(services, packageName, className))
        assertFalse(
            AccessibilityServiceListPolicy.isEnabled("$shortForm:garbage", "com.example", className),
        )
    }

    /** The accessibility tamper check and the setup checklist must agree on both forms. */
    @Test
    fun `AccessibilityOffPolicy delegates to the shared parser for both forms`() {
        assertTrue(AccessibilityOffPolicy.isServiceEnabled(fullyQualified, fullyQualified))
        assertTrue(AccessibilityOffPolicy.isServiceEnabled(shortForm, fullyQualified))
        assertFalse(
            AccessibilityOffPolicy.isServiceEnabled(
                "$packageName/.services.OtherService",
                fullyQualified,
            ),
        )
    }
}
