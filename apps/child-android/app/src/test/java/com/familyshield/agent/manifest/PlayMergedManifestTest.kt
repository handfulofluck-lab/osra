package com.familyshield.agent.manifest

import com.familyshield.agent.security.GuardianAdminReceiver
import com.familyshield.agent.services.AccessibilityMonitorService
import java.io.File
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test

/**
 * ADR-0021's merged-manifest gate, **Play half**: the artefact Play would receive.
 *
 * It asserts the manifest AGP produced after merging (`merged_manifests/playDebug/…/AndroidManifest.xml`),
 * not the source files. That distinction is the whole point (finding F2, #101 review): a dependency's
 * `READ_SMS` or notification listener exists only in the merged file, so a source-text test — and CI's
 * `aapt2 dump badging`, which prints no permissions — stays green while the store build carries it.
 *
 * The gate is an allow list **and** a deny list. The deny list says what Play policy forbids and why
 * (ADR-0021 decisions 1, 2, 5); the allow list is the reviewed permission set, so a permission that
 * arrives with a dependency upgrade and matches no rule still fails until someone decides it is
 * permitted. `scripts/check-merged-manifest-gate.mjs` fails CI if this class did not run or skipped.
 */
class PlayMergedManifestTest {

    private val artifact: File? by lazy { MergedManifestLocator.locate("play") }
    private val merged: MergedManifest by lazy { MergedManifest.read(artifact!!) }
    private val releaseArtifact: File? by lazy { MergedManifestLocator.locate("play", "Release") }
    private val releaseMerged: MergedManifest by lazy { MergedManifest.read(releaseArtifact!!) }

    @Before
    fun theMergedManifestMustExist() {
        MergedManifestLocator.require(artifact, "play")
        MergedManifestLocator.require(releaseArtifact, "play", "Release")
        println("merged-manifest gate (play debug): ${artifact!!.absolutePath}")
        println("merged-manifest gate (play release): ${releaseArtifact!!.absolutePath}")
    }

    @Test
    fun `play merged manifest declares exactly the reviewed permission allow-list`() {
        val actual = merged.includedPermissions
        val unexpected = actual - PlayManifestPolicy.ALLOWED_PERMISSIONS.keys
        val missing = PlayManifestPolicy.ALLOWED_PERMISSIONS.keys - actual
        assertTrue(
            "the Play artefact's merged permission set changed: unexpected=$unexpected, missing=$missing. " +
                "Every entry in PlayManifestPolicy.ALLOWED_PERMISSIONS is a Play policy decision " +
                "(ADR-0021); review the addition before changing the list.",
            unexpected.isEmpty() && missing.isEmpty(),
        )
    }

    @Test
    fun `play merged manifest declares none of the Play-forbidden permissions`() {
        val violations = PlayManifestPolicy.permissionViolations(merged)
        assertTrue(
            "the Play artefact carries a permission Play forbids or nobody reviewed — most likely a " +
                "library's manifest. Find the source in " +
                "app/build/outputs/logs/manifest-merger-play-debug-report.txt (per-element blame: " +
                "app/build/intermediates/manifest_merge_blame_file/playDebug/**/" +
                "manifest-merger-blame-play-debug-report.txt):\n" +
                violations.joinToString("\n"),
            violations.isEmpty(),
        )
    }

    @Test
    fun `play merged manifest registers no notification, call-log or SMS component`() {
        val violations = PlayManifestPolicy.componentViolations(merged)
        assertTrue(
            "the Play artefact registers a component or intent filter that belongs to the Full build " +
                "(ADR-0016 §4, ADR-0021 decision 2):\n" + violations.joinToString("\n"),
            violations.isEmpty(),
        )
    }

    @Test
    fun `play merged manifest keeps isMonitoringTool and the required queries`() {
        val violations = PlayManifestPolicy.monitoringViolations(merged) + PlayManifestPolicy.queryViolations(merged)
        assertTrue(
            "the Play artefact lost a declaration Play or S1 depends on (ADR-0021 decisions 3 and 5):\n" +
                violations.joinToString("\n"),
            violations.isEmpty(),
        )
    }

    /**
     * Issue #170: a test runner must be able to **replace** the package without the parent PIN, which
     * Android only permits for a `testOnly` package. The debug overlay declares it; neither source set
     * shared with release does. It is not the cleanup route: since #217 admin removal is the app's
     * REMOVE PROTECTION (PARENT PIN).
     */
    @Test
    fun `play debug merged manifest is testOnly so a test runner may replace the package`() {
        assertTrue(
            "android:testOnly is absent from the Play debug merge. A test runner can then not replace " +
                "the package without the parent PIN (issue #170). Declare it in app/src/debug/AndroidManifest.xml.",
            merged.applicationTestOnly == "true",
        )
    }

    /**
     * Issue #170's other half: `testOnly` makes an APK trivially replaceable, so release must not carry it.
     */
    @Test
    fun `play release merged manifest is not testOnly`() {
        assertNull(
            "android:testOnly=${releaseMerged.applicationTestOnly} is declared in the Play RELEASE merged " +
                "manifest. `testOnly` is exactly what lets an APK be replaced without the parent's consent " +
                "(issue #170); it belongs only in app/src/debug/AndroidManifest.xml.",
            releaseMerged.applicationTestOnly,
        )
    }

    /**
     * Roadmap 3.2: the QR scanner is a user-facing feature, so both flavours carry CAMERA. The allow
     * list above is the policy decision; this test keeps the declaration and the decision together.
     */
    @Test
    fun `play merged manifest keeps the camera permission the QR scanner needs`() {
        assertTrue(
            "android.permission.CAMERA is missing from the Play merged manifest, so the store build " +
                "cannot scan the parent's pairing QR code (roadmap 3.2).",
            "android.permission.CAMERA" in merged.includedPermissions,
        )
        assertTrue(
            "CAMERA is absent from PlayManifestPolicy.ALLOWED_PERMISSIONS — a Play policy decision " +
                "must be recorded there, not assumed by the manifest.",
            "android.permission.CAMERA" in PlayManifestPolicy.ALLOWED_PERMISSIONS,
        )
    }

    /**
     * Issue #217: the system sheets name the app from `<application android:label>`. Without it Android
     * fell back to the Application class (`com.familyshield.agent.FamilyShieldApp`) in the camera prompt
     * and the device-admin sheet; the accessibility service was listed by class name too. Asserted on the
     * merged artefact because that is what the phone installs.
     */
    @Test
    fun `play merged manifest labels the application and the accessibility service`() {
        val violations = PlayManifestPolicy.labellingViolations(
            merged,
            accessibilityServiceClass = AccessibilityMonitorService::class.java.name,
        )
        assertTrue(
            "the Play artefact would name the app after its Application class in system sheets " +
                "(issue #217):\n" + violations.joinToString("\n"),
            violations.isEmpty(),
        )
    }

    /**
     * Issue #202: the installed component name is what Samsung's Knox registry matches. The rename is
     * only real if the merged Play manifest carries it with the admin contract intact.
     */
    @Test
    fun `play merged manifest declares the renamed device-admin receiver`() {
        val violations = PlayManifestPolicy.adminReceiverViolations(
            merged,
            GuardianAdminReceiver.COMPONENT_CLASS,
        )
        assertTrue(
            "the Play artifact's device-admin receiver changed (issue #202):\n" +
                violations.joinToString("\n"),
            violations.isEmpty(),
        )
    }
}
