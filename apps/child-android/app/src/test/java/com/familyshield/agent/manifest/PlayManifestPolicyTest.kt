package com.familyshield.agent.manifest

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Pins the checker itself: `PlayManifestPolicy` must flag a forbidden declaration that arrives **through
 * the merge**, because that is the case `FlavorManifestTest`'s source-text assertions cannot see.
 *
 * These fixtures are merged manifests with one injected element — the shape a library adds. They fail
 * before the policy exists (there was no policy), and they keep a later "simplification" of the gate from
 * turning the allow list back into a single `contains()` on one permission.
 */
class PlayManifestPolicyTest {

    private val requiredQueries = """
        <queries>
            <intent>
                <action android:name="android.intent.action.MAIN" />
                <category android:name="android.intent.category.LAUNCHER" />
            </intent>
            <intent>
                <action android:name="android.intent.action.MAIN" />
                <category android:name="android.intent.category.HOME" />
            </intent>
            <intent>
                <action android:name="com.android.phone.EmergencyDialer.DIAL" />
            </intent>
            <intent>
                <action android:name="android.intent.action.DIAL" />
            </intent>
        </queries>
    """.trimIndent()

    private fun merged(
        extraPermissions: List<String> = emptyList(),
        extraComponents: String = "",
        queries: String = requiredQueries,
        monitoringValue: String = PlayManifestPolicy.MONITORING_VALUE,
    ): MergedManifest {
        val permissions = (PlayManifestPolicy.ALLOWED_PERMISSIONS.keys + extraPermissions)
            .joinToString("\n") { """<uses-permission android:name="$it" />""" }
        val monitoring = if (monitoringValue.isEmpty()) {
            ""
        } else {
            """<meta-data android:name="${PlayManifestPolicy.MONITORING_FLAG}" android:value="$monitoringValue" />"""
        }
        return MergedManifest.parse(
            """
            <manifest xmlns:android="http://schemas.android.com/apk/res/android" package="com.familyshield.agent">
                $queries
                $permissions
                <application android:name="com.familyshield.agent.FamilyShieldApp">
                    $monitoring
                    $extraComponents
                </application>
            </manifest>
            """.trimIndent(),
        )
    }

    private fun assertNoViolations(manifest: MergedManifest) {
        assertEquals(emptyList<String>(), PlayManifestPolicy.permissionViolations(manifest))
        assertEquals(emptyList<String>(), PlayManifestPolicy.componentViolations(manifest))
        assertEquals(emptyList<String>(), PlayManifestPolicy.queryViolations(manifest))
        assertEquals(emptyList<String>(), PlayManifestPolicy.monitoringViolations(manifest))
    }

    @Test
    fun `the reviewed baseline is clean`() {
        assertNoViolations(merged())
    }

    @Test
    fun `a forbidden permission injected by a dependency fails the deny list`() {
        val violations = PlayManifestPolicy.permissionViolations(merged(extraPermissions = listOf("android.permission.READ_SMS")))
        assertTrue(violations.toString(), violations.single().startsWith("FORBIDDEN android.permission.READ_SMS"))
    }

    @Test
    fun `a permission no rule names still fails the allow-list`() {
        val violations = PlayManifestPolicy.permissionViolations(
            merged(extraPermissions = listOf("android.permission.MANAGE_OWN_CALLS")),
        )
        assertTrue(violations.toString(), violations.single().startsWith("UNREVIEWED android.permission.MANAGE_OWN_CALLS"))
    }

    @Test
    fun `a notification listener injected by a dependency fails the component check`() {
        val listener = """
            <service
                android:name="com.example.sdk.NotificationCaptureService"
                android:permission="android.permission.BIND_NOTIFICATION_LISTENER_SERVICE"
                android:exported="true">
                <intent-filter>
                    <action android:name="android.service.notification.NotificationListenerService" />
                </intent-filter>
            </service>
        """.trimIndent()
        val violations = PlayManifestPolicy.componentViolations(merged(extraComponents = listener))
        assertTrue(violations.toString(), violations.any { "NotificationCaptureService" in it })
        assertTrue(violations.toString(), violations.any { "android.service.notification.NotificationListenerService" in it })
    }

    @Test
    fun `an SMS receiver injected by a dependency fails the component check`() {
        val receiver = """
            <receiver android:name="com.example.sdk.SmsReceiver" android:exported="true">
                <intent-filter>
                    <action android:name="android.provider.Telephony.SMS_RECEIVED" />
                </intent-filter>
            </receiver>
        """.trimIndent()
        val violations = PlayManifestPolicy.componentViolations(merged(extraComponents = receiver))
        assertTrue(violations.toString(), violations.single().contains("android.provider.Telephony.SMS_RECEIVED"))
    }

    @Test
    fun `a flavour that drops the emergency dialer query fails the query check`() {
        val queries = """
            <queries>
                <intent>
                    <action android:name="android.intent.action.MAIN" />
                    <category android:name="android.intent.category.LAUNCHER" />
                </intent>
                <intent>
                    <action android:name="android.intent.action.MAIN" />
                    <category android:name="android.intent.category.HOME" />
                </intent>
            </queries>
        """.trimIndent()
        val violations = PlayManifestPolicy.queryViolations(merged(queries = queries))
        assertEquals(2, violations.size)
        assertTrue(violations.toString(), violations.any { "com.android.phone.EmergencyDialer.DIAL" in it })
        assertTrue(violations.toString(), violations.any { "android.intent.action.DIAL" in it })
    }

    @Test
    fun `a missing isMonitoringTool declaration fails the monitoring check`() {
        val violations = PlayManifestPolicy.monitoringViolations(merged(monitoringValue = ""))
        assertTrue(violations.toString(), violations.single().contains("isMonitoringTool"))
    }
}
