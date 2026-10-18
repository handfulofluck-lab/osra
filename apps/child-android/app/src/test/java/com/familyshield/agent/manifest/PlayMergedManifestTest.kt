package com.familyshield.agent.manifest

import java.io.File
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

    @Before
    fun theMergedManifestMustExist() {
        MergedManifestLocator.require(artifact, "play")
        println("merged-manifest gate (play): ${artifact!!.absolutePath}")
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
}
