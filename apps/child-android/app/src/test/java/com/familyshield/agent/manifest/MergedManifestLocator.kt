package com.familyshield.agent.manifest

import java.io.File
import org.junit.Assume

/**
 * Finds the merged manifest AGP wrote for a flavour. The production path is
 * `app/build/intermediates/merged_manifests/<flavor>Debug/…/AndroidManifest.xml`, produced by
 * `process<Flavor>DebugManifest`; `build.gradle.kts` makes both debug unit-test tasks depend on the
 * merge of **both** flavours, so the artefact is present whenever the suite runs under Gradle.
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
        System.getProperty("osra.mergedManifest.$flavor")?.let { override ->
            return File(override).takeIf { it.isFile }
        }

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
    fun require(file: File?, flavor: String) {
        if (file != null) return
        val message = buildString {
            append("MERGED-MANIFEST GATE SKIPPED: no merged $flavor Debug manifest found. ")
            append("The gate reads app/build/intermediates/merged_manifests/")
            append("${flavor}Debug/**/AndroidManifest.xml, which `./gradlew test")
            append(flavor.replaceFirstChar { it.uppercase() })
            append("DebugUnitTest` produces (it depends on process<Flavor>DebugManifest). ")
            append("Set -Dosra.mergedManifest.$flavor=<path> to point it at a manifest explicitly. ")
            append("CI fails on this skip (scripts/check-merged-manifest-gate.mjs).")
        }
        System.err.println(message)
        Assume.assumeTrue(message, false)
    }
}
