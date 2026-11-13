package com.familyshield.agent.update

import java.io.File
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * R2 (Ahmed's finding on #615): the install-confirmation intent must resolve to a system image before it is
 * started. `confirmationIntentMustResolveToSystemInstaller` pins the policy; this row pins the one fact a pure
 * test cannot see, that [FullUpdater] asks the policy at all and refuses on it — Claude's fault f4 (skip the
 * policy call) survived every other row, which is what a source row is for.
 */
class FullUpdaterConfirmSourceTest {

    @Test
    fun `confirmationIntent asks the system-installer policy and refuses on it`() {
        val source: String = FULL_UPDATER.readText()
        val body: String = source
            .split("\n        private fun ")
            .firstOrNull { chunk: String -> chunk.startsWith("confirmationIntent(") }
            .orEmpty()
        assertTrue("confirmationIntent was not found in ${FULL_UPDATER.path}", body.isNotEmpty())
        assertTrue(
            "the confirmation intent must be resolved against system apps only",
            body.contains("MATCH_SYSTEM_ONLY"),
        )
        assertTrue(
            "confirmationIntent must ask FullUpdatePolicy.confirmationTargetIsSystemInstaller",
            body.contains("confirmationTargetIsSystemInstaller"),
        )
        val refusal: String = body
            .split("if (!")
            .getOrNull(1)
            ?.substringBefore(") {")
            .orEmpty()
        assertTrue(
            "the policy call must sit in an if (!…) that refuses, not be logged and ignored",
            refusal.contains("confirmationTargetIsSystemInstaller"),
        )
        assertTrue(
            "the refusing branch must return null so the intent is never started",
            body.contains("return null"),
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
