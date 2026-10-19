package com.familyshield.agent.manifest

import java.io.File
import org.junit.Assume

/**
 * Finds the merged manifest AGP wrote for a flavour and build type. The production paths are
 * `app/build/intermediates/merged_manifests/<flavor>Debug/…/AndroidManifest.xml` and
 * `…/<flavor>Release/…/AndroidManifest.xml`, produced by `process<Flavor>DebugManifest` /
 * `process<Flavor>ReleaseManifest`; `build.gradle.kts` makes both debug unit-test tasks depend on the
 * merge of **both** flavours and **both** build types, so the artefacts are present whenever the suite
 * runs under Gradle. Issue #170 needs the release half: `testOnly` must be absent there.
 *
 * The search walks up from the test's working directory (Gradle uses the project dir,
 * `apps/child-android`) instead of hard-coding a relative path, and accepts any depth below the variant
 * directory because AGP adds a task-name folder in some versions (`…/processPlayDebugManifest/…`).
 *
 * Run outside Gradle (an IDE test runner, a single JUnit invocation), the artefact may not exist. That
 * is the only case in which the gate is allowed to skip, and it says so loudly: CI runs
 * `scripts/check-merged-manifest-gate.mjs`, which fails the job if a gate test or the suite is skipped.
 */
object MergedManifestLocator {

    fun locate(flavor: String, buildType: String = "Debug"): File? {
        // Issue #170: the release manifest is read too, so the override must be per build type. The
        // unsuffixed key stays valid for Debug — it is in the docs and prior run logs.
        val overrides = listOfNotNull(
            System.getProperty("osra.mergedManifest.$flavor$buildType"),
            if (buildType == "Debug") System.getProperty("osra.mergedManifest.$flavor") else null,
        )
        overrides.forEach { override -> File(override).takeIf { it.isFile }?.let { return it } }

        var dir: File? = File(System.getProperty("user.dir") ?: ".").absoluteFile
        while (dir != null) {
            val variantDir = File(dir, "app/build/intermediates/merged_manifests/$flavor$buildType")
            if (variantDir.isDirectory) {
                val candidates = variantDir.walkTopDown()
                    .filter { it.isFile && it.name == "AndroidManifest.xml" }
                    .toList()
                // Newest wins: with AGP's task-name subfolder there is one, and a stale copy from an
                // older layout must not shadow the merge that just ran.
                candidates.maxByOrNull { it.lastModified() }?.let { return it }
            }
            dir = dir.parentFile
        }
        return null
    }

    /** Fails the test as *skipped* with a message a human and the CI guard can both read. */
    fun require(file: File?, flavor: String, buildType: String = "Debug") {
        if (file != null) return
        val variant = "$flavor$buildType"
        val message = buildString {
            append("MERGED-MANIFEST GATE SKIPPED: no merged $variant manifest found. ")
            append("The gate reads app/build/intermediates/merged_manifests/")
            append("$variant/**/AndroidManifest.xml, which `./gradlew test")
            append(flavor.replaceFirstChar { it.uppercase() })
            append("DebugUnitTest` produces (it depends on process${flavor.replaceFirstChar { it.uppercase() }}DebugManifest ")
            append("and process${flavor.replaceFirstChar { it.uppercase() }}ReleaseManifest). ")
            append("Set -Dosra.mergedManifest.$variant=<path> to point it at a manifest explicitly. ")
            append("CI fails on this skip (scripts/check-merged-manifest-gate.mjs).")
        }
        System.err.println(message)
        Assume.assumeTrue(message, false)
    }
}
