package com.familyshield.agent.update

import java.io.File
import org.junit.Assert.assertEquals
import org.junit.Test

/**
 * ADR-0039 amendment row 5, last bullet: `PackageInstaller` is referenced from exactly one file, and that
 * file is `FullUpdater.kt`. The rule is what makes "no server command, push, intent or deep link may start
 * an install" checkable: a second reference is how such a path would appear.
 *
 * The module directory is found by walking up from the test's working directory, as `FlavorManifestTest`
 * does, because Gradle runs the suite from the project directory and an IDE may run it from the module.
 */
class PackageInstallerSingleSourceTest {

    @Test
    fun `PackageInstaller is referenced from exactly one Kotlin file and it is FullUpdater`() {
        val root: File = moduleRoot()
        val hits: List<String> = SOURCE_SETS
            .flatMap { sourceSet: String ->
                File(root, "app/src/$sourceSet").walkTopDown()
                    .filter { file: File -> file.isFile && file.extension == "kt" }
                    .filter { file: File -> file.readText().contains(MARKER) }
                    .map { file: File -> file.relativeTo(root).invariantSeparatorsPath }
                    .toList()
            }
            .sorted()
        assertEquals(
            "only $EXPECTED may touch $MARKER (ADR-0039 amendment row 5): a second file is a second way " +
                "to start an install, which the ADR forbids",
            listOf(EXPECTED),
            hits,
        )
    }

    private fun moduleRoot(): File {
        var dir: File? = File(System.getProperty("user.dir") ?: ".").absoluteFile
        while (dir != null) {
            if (File(dir, "app/src/main/java").isDirectory) return dir
            dir = dir.parentFile
        }
        throw AssertionError("could not find the app module from ${System.getProperty("user.dir")}")
    }

    private companion object {
        const val MARKER: String = "PackageInstaller"
        const val EXPECTED: String = "app/src/main/java/com/familyshield/agent/update/FullUpdater.kt"
        val SOURCE_SETS: List<String> = listOf("main", "full", "play")
    }
}
