package com.familyshield.agent.update

import java.io.File
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * R1 (Ahmed's finding on #615): `hasOwnSigner` must read the archive's `signingCertificateHistory`, not only
 * its current signers, or a planned `old -> new` rotation is refused as `foreign_signer` — the exact update
 * the check exists to allow. `rotatedSignerStillAccepted` pins the decision; this row pins the one fact a pure
 * test cannot see, that the adapter hands the policy the lineage at all.
 */
class FullUpdaterSignerSourceTest {

    @Test
    fun `hasOwnSigner reads the archive's signing certificate history`() {
        val source: String = FULL_UPDATER.readText()
        val body: String = source
            .split("\n    private fun ")
            .firstOrNull { chunk: String -> chunk.startsWith("hasOwnSigner(") }
            .orEmpty()
        assertTrue("hasOwnSigner was not found in ${FULL_UPDATER.path}", body.isNotEmpty())
        assertTrue(
            "hasOwnSigner must pass the archive's lineage to the policy, not only its current signers",
            body.contains("signingCertificateHistory"),
        )
        assertTrue(
            "hasOwnSigner must hand the shape to FullUpdatePolicy.checkArchiveSigners",
            body.contains("checkArchiveSigners"),
        )
    }

    private companion object {
        val FULL_UPDATER: File = moduleRoot()
            .resolve("app/src/full/java/com/familyshield/agent/update/FullUpdater.kt")

        fun moduleRoot(): File {
            var dir: File? = File(System.getProperty("user.dir") ?: ".").absoluteFile
            while (dir != null) {
                if (File(dir, "app/src/main/java").isDirectory) return dir
                dir = dir.parentFile
            }
            throw AssertionError("could not find the app module from ${System.getProperty("user.dir")}")
        }
    }
}
