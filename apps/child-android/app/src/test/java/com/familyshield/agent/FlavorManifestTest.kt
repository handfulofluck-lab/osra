package com.familyshield.agent

import java.io.File
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * ADR-0016 §5: the flavor split is a build-time fact, and it is exactly the kind of fact that
 * regresses silently when someone "simplifies" a manifest. This reads the two manifests as text —
 * the unit suite has no AGP model — and pins the difference that matters: the Play (main) manifest
 * must not be able to receive a notification, and the Full manifest must register the listener.
 */
class FlavorManifestTest {

    private fun manifest(relative: String): String {
        var dir: File? = File(System.getProperty("user.dir")).absoluteFile
        while (dir != null) {
            val candidate = File(dir, relative)
            if (candidate.isFile) return candidate.readText()
            dir = dir.parentFile
        }
        throw AssertionError("could not find $relative from ${System.getProperty("user.dir")}")
    }

    private val mainManifest by lazy { manifest("app/src/main/AndroidManifest.xml") }
    private val fullManifest by lazy { manifest("app/src/full/AndroidManifest.xml") }

    @Test
    fun `the shared manifest cannot receive a notification`() {
        assertFalse(
            "src/main must not declare the listener permission - the Play artefact would carry it",
            mainManifest.contains("BIND_NOTIFICATION_LISTENER_SERVICE"),
        )
        assertFalse(
            "src/main must not register a NotificationListenerService",
            mainManifest.contains("android.service.notification.NotificationListenerService"),
        )
        assertFalse(
            "the capture service class must not be referenced from src/main",
            mainManifest.contains("NotificationCaptureService"),
        )
    }

    @Test
    fun `the full manifest declares the permission and registers the service`() {
        assertTrue(fullManifest.contains("BIND_NOTIFICATION_LISTENER_SERVICE"))
        assertTrue(fullManifest.contains("android.service.notification.NotificationListenerService"))
        assertTrue(
            "the registered class must be the one under src/full",
            fullManifest.contains(".services.NotificationCaptureService"),
        )
        assertTrue(
            "the service must require the system permission, not merely declare it",
            fullManifest.contains("android:permission=\"android.permission.BIND_NOTIFICATION_LISTENER_SERVICE\""),
        )
    }

    @Test
    fun `the capture service source exists only in the full source set`() {
        val fullSource = manifest("app/src/full/java/com/familyshield/agent/services/NotificationCaptureService.kt")
        assertTrue(fullSource.contains("NotificationListenerService"))
        val playSource = File(System.getProperty("user.dir"))
        var dir: File? = playSource.absoluteFile
        while (dir != null) {
            if (File(dir, "app/src/main/java/com/familyshield/agent/services/NotificationCaptureService.kt").isFile) {
                throw AssertionError("NotificationCaptureService must not exist in src/main (ADR-0016)")
            }
            dir = dir.parentFile
        }
    }

    /**
     * ADR-0021: Play's SMS/Call-Log policy has no exception for parental control, so the shared manifest
     * must not declare those permissions; the Full manifest carries them. The narrow `<queries>` block
     * replaces QUERY_ALL_PACKAGES and must keep the two dialer intents — #83's emergency-dialer exemption
     * resolves them at runtime (S1 on the store build depends on it).
     */
    @Test
    fun `play declares no call-log or SMS permission and keeps the dialer queries`() {
        for (permission in listOf("READ_CALL_LOG", "READ_SMS", "QUERY_ALL_PACKAGES")) {
            assertFalse(
                "src/main must not declare $permission (ADR-0021)",
                mainManifest.contains("android.permission.$permission"),
            )
        }
        assertTrue("the launcher query is needed for the app grid", mainManifest.contains("android.intent.category.LAUNCHER"))
        assertTrue("the HOME query is needed for the launcher exemption (#165)", mainManifest.contains("android.intent.category.HOME"))
        assertTrue(
            "the emergency-dialer intent must stay visible (#83/S1)",
            mainManifest.contains("com.android.phone.EmergencyDialer.DIAL"),
        )
        assertTrue("the DIAL intent must stay visible (#83)", mainManifest.contains("android.intent.action.DIAL"))
    }

    @Test
    fun `the shared manifest declares isMonitoringTool and full carries the call and SMS permissions`() {
        // The declaration lives in src/main on purpose, so manifest merging puts it in BOTH artefacts;
        // asserting it in the full *source file* is wrong, because that file only adds the capability.
        assertTrue(
            "src/main must declare isMonitoringTool=child_monitoring (Play monitoring policy)",
            mainManifest.contains("isMonitoringTool") && mainManifest.contains("child_monitoring"),
        )
        assertFalse(
            "the full source file must not declare it again - one declaration, merged into both",
            fullManifest.contains("isMonitoringTool"),
        )
        assertTrue(fullManifest.contains("android.permission.READ_CALL_LOG"))
        assertTrue(fullManifest.contains("android.permission.READ_SMS"))
    }

    /**
     * ADR-0021's class clause: the call/SMS capture implementation lives in `full` and the shared source
     * set only knows the interface, so the Play artefact cannot contain the code path at all.
     */
    @Test
    fun `the call and SMS capture implementation exists only in the full source set`() {
        val full = manifest("app/src/full/java/com/familyshield/agent/comms/CommsLogger.kt")
        assertTrue(full.contains("CommsCapture"))
        var dir: File? = File(System.getProperty("user.dir")).absoluteFile
        while (dir != null) {
            if (File(dir, "app/src/main/java/com/familyshield/agent/comms/CommsLogger.kt").isFile) {
                throw AssertionError("CommsLogger must not exist in src/main (ADR-0021)")
            }
            dir = dir.parentFile
        }
        assertTrue(manifest("app/src/main/java/com/familyshield/agent/comms/CommsCapture.kt").contains("interface CommsCapture"))
        assertTrue(manifest("app/src/play/java/com/familyshield/agent/di/CommsBindingModule.kt").contains("NoopCommsCapture"))
        assertTrue(manifest("app/src/full/java/com/familyshield/agent/di/CommsBindingModule.kt").contains("CommsLogger"))
    }

    /**
     * Issue #128: `BootReceiver` may start `LocationService`, and (when the tunnel is enabled)
     * `FilterVpnService`. Both are foreground services on API 34+, so each needs a declared
     * `foregroundServiceType` and the matching `FOREGROUND_SERVICE_*` permission — a missing pair is
     * a `SecurityException` at `startForeground()`.
     */
    @Test
    fun `services the boot receiver starts declare an FGS type and its permission`() {
        val location = serviceTag(".services.LocationService")
        assertTrue(location, location.contains("""android:foregroundServiceType="location""""))
        assertTrue(
            "a location FGS needs FOREGROUND_SERVICE_LOCATION",
            mainManifest.contains("android.permission.FOREGROUND_SERVICE_LOCATION"),
        )

        val vpn = serviceTag(".vpn.FilterVpnService")
        assertTrue(vpn, vpn.contains("""android:foregroundServiceType="specialUse""""))
        assertTrue(
            "a specialUse FGS needs FOREGROUND_SERVICE_SPECIAL_USE",
            mainManifest.contains("android.permission.FOREGROUND_SERVICE_SPECIAL_USE"),
        )
    }

    private fun serviceTag(name: String): String =
        Regex(
            "<service\\b[^>]*android:name=\"${Regex.escape(name)}\"[^>]*>",
            RegexOption.DOT_MATCHES_ALL,
        ).find(mainManifest)?.value ?: throw AssertionError("no <service> declaration for $name")
}
