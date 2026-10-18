package com.familyshield.agent.manifest

import java.io.File
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test

/**
 * ADR-0021's merged-manifest gate, **Full half**. The same merge is read as the Play half reads it, but
 * the assertions run the other way: the sideloaded build must keep the capture permissions, the
 * notification listener and the monitoring declaration, because moving a capability to `src/full` is
 * only safe while Full still has it. A flavour split that fails here is a lost feature, not a Play risk.
 */
class FullMergedManifestTest {

    private val artifact: File? by lazy { MergedManifestLocator.locate("full") }
    private val merged: MergedManifest by lazy { MergedManifest.read(artifact!!) }

    @Before
    fun theMergedManifestMustExist() {
        MergedManifestLocator.require(artifact, "full")
        println("merged-manifest gate (full): ${artifact!!.absolutePath}")
    }

    @Test
    fun `full merged manifest keeps the capture permissions and the listener service`() {
        val expectedPermissions = listOf(
            "android.permission.READ_CALL_LOG",
            "android.permission.READ_SMS",
            "android.permission.BIND_NOTIFICATION_LISTENER_SERVICE",
        )
        val problems = mutableListOf<String>()
        expectedPermissions.filterNot { it in merged.includedPermissions }
            .forEach { problems += "missing permission $it (ADR-0021 decision 2 / ADR-0016 §4)" }

        val listener = merged.components.firstOrNull { it.name.endsWith("NotificationCaptureService") }
        if (listener == null) {
            problems += "no NotificationCaptureService component — the Full build would capture no notifications"
        } else {
            if ("android.service.notification.NotificationListenerService" !in listener.intentActions) {
                problems += "NotificationCaptureService has no android.service.notification.NotificationListenerService intent filter"
            }
            if (listener.permission != "android.permission.BIND_NOTIFICATION_LISTENER_SERVICE") {
                problems += "NotificationCaptureService must require BIND_NOTIFICATION_LISTENER_SERVICE, " +
                    "found ${listener.permission ?: "no android:permission"}"
            }
        }
        assertTrue(
            "the Full artefact lost a capability the flavor split was supposed to keep:\n" +
                problems.joinToString("\n"),
            problems.isEmpty(),
        )
    }

    @Test
    fun `full merged manifest keeps isMonitoringTool and the dialer queries`() {
        val violations = PlayManifestPolicy.monitoringViolations(merged) +
            PlayManifestPolicy.queryViolations(merged)
        assertTrue(
            "the Full artefact must carry the same monitoring declaration and dialer queries as Play " +
                "(ADR-0021 decisions 3 and 5; Play Protect reads the flag on sideloads):\n" +
                violations.joinToString("\n"),
            violations.isEmpty(),
        )
    }
}
