package com.familyshield.agent.manifest

import com.familyshield.agent.security.ParentalAdminReceiver
import java.io.File
import org.junit.Assert.assertNull
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
    private val releaseArtifact: File? by lazy { MergedManifestLocator.locate("full", "Release") }
    private val releaseMerged: MergedManifest by lazy { MergedManifest.read(releaseArtifact!!) }

    @Before
    fun theMergedManifestMustExist() {
        MergedManifestLocator.require(artifact, "full")
        MergedManifestLocator.require(releaseArtifact, "full", "Release")
        println("merged-manifest gate (full debug): ${artifact!!.absolutePath}")
        println("merged-manifest gate (full release): ${releaseArtifact!!.absolutePath}")
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
    fun `full merged manifest keeps isMonitoringTool and the required queries`() {
        val violations = PlayManifestPolicy.monitoringViolations(merged) +
            PlayManifestPolicy.queryViolations(merged)
        assertTrue(
            "the Full artefact must carry the same monitoring declaration and package-visibility " +
                "queries as Play " +
                "(ADR-0021 decisions 3 and 5; Play Protect reads the flag on sideloads):\n" +
                violations.joinToString("\n"),
            violations.isEmpty(),
        )
    }

    /**
     * Issue #170: the hardware cleanup path is `dpm remove-active-admin`, which Android refuses for a
     * non-test admin. A Full debug build is the artefact the test runner installs, so it must be testOnly.
     */
    @Test
    fun `full debug merged manifest is testOnly so the test admin is removable`() {
        assertTrue(
            "android:testOnly is absent from the Full debug merge. The test runner cannot run " +
                "`dpm remove-active-admin` without it (issue #170), so cleanup again needs the app PIN. " +
                "Declare it in app/src/debug/AndroidManifest.xml.",
            merged.applicationTestOnly == "true",
        )
    }

    /**
     * Issue #170's acceptance: the sideloaded release build keeps the hard admin. `testOnly` would let
     * anyone replace the package without the parent PIN, so it must be absent from `assembleFullRelease`.
     */
    @Test
    fun `full release merged manifest is not testOnly`() {
        assertNull(
            "android:testOnly=${releaseMerged.applicationTestOnly} is declared in the Full RELEASE merged " +
                "manifest. `testOnly` is exactly what lets an APK be replaced without the parent's consent " +
                "(issue #170); it belongs only in app/src/debug/AndroidManifest.xml.",
            releaseMerged.applicationTestOnly,
        )
    }

    /** Roadmap 3.2: CAMERA is a user-facing feature of the sideloaded flavour too. */
    @Test
    fun `full merged manifest keeps the camera permission the QR scanner needs`() {
        assertTrue(
            "android.permission.CAMERA is missing from the Full merged manifest, so the sideloaded " +
                "build cannot scan the parent's pairing QR code (roadmap 3.2).",
            "android.permission.CAMERA" in merged.includedPermissions,
        )
    }

    /**
     * Issue #202: the Full APK is the artefact the hardware rows install, and the installed component
     * name is what Samsung's Knox registry matches. The rename must survive this flavour's merge too.
     */
    @Test
    fun `full merged manifest declares the renamed device-admin receiver`() {
        val violations = PlayManifestPolicy.adminReceiverViolations(
            merged,
            ParentalAdminReceiver.COMPONENT_CLASS,
        )
        assertTrue(
            "the Full artifact's device-admin receiver changed (issue #202):\n" +
                violations.joinToString("\n"),
            violations.isEmpty(),
        )
    }
}
