package com.familyshield.agent

import java.io.File
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Issue #132: #128 fixed the boot path, but two other *background* call sites still requested
 * `LocationService` with only a while-in-use grant, and a fourth one added tomorrow would reopen the
 * same `ForegroundServiceDidNotStartInTimeException` class of failure silently. There is exactly one
 * rule for those sites (`LocationStartPolicy`; `BootStartPolicy` delegates to it for the boot row),
 * so every file that asks for `LocationService` by class must either go through it or be listed
 * below as a foreground start.
 *
 * The unit suite has no AGP model, so this reads the sources as text — the same technique
 * `FlavorManifestTest` uses for the manifests. It proves a reference, not the semantics; the
 * semantics are `LocationStartPolicyTest` and the two call-site tests.
 */
class LocationServiceStartSitesTest {

    @Test
    fun `every LocationService start site goes through the start policy`() {
        val sites = sourceRoot("app/src/main/java")
            .walkTopDown()
            .filter { it.isFile && it.extension == "kt" }
            .filter { file ->
                val text = file.readText()
                text.contains("startForegroundService") && text.contains("LocationService::class.java")
            }
            .toList()

        val names = sites.map { it.name }.toSet()
        assertTrue(
            "expected the known start sites, found $names — the scan or a rename is wrong",
            names.containsAll(
                FOREGROUND_START_SITES + setOf(
                    "BootReceiver.kt",
                    "AccessibilityMonitorService.kt",
                    "CommandDispatcher.kt",
                ),
            ),
        )

        val unguarded = sites.filter { file ->
            val text = file.readText()
            file.name !in FOREGROUND_START_SITES &&
                !text.contains("LocationStartPolicy") &&
                !text.contains("BootStartPolicy")
        }
        assertTrue(
            "these files request LocationService without a background-location policy: " +
                unguarded.map { it.name },
            unguarded.isEmpty(),
        )
    }

    private fun sourceRoot(relative: String): File {
        var dir: File? = File(System.getProperty("user.dir")).absoluteFile
        while (dir != null) {
            val candidate = File(dir, relative)
            if (candidate.isDirectory) return candidate
            dir = dir.parentFile
        }
        throw AssertionError("could not find $relative from ${System.getProperty("user.dir")}")
    }

    companion object {
        /**
         * Started from a resumed activity, not from the background: the FGS is created while the
         * app is in the foreground, so the while-in-use grant is enough and `ACCESS_BACKGROUND_LOCATION`
         * is not a precondition (Android 14's background rule applies to background starts). The
         * activity asks for the background grant as its second prompt; if the child denies it, the
         * still-running service is the same outcome as before #132. A *new* entry here is a claim
         * that the start happens with the activity visible, not a way to silence the check.
         */
        private val FOREGROUND_START_SITES = setOf("PairingActivity.kt")
    }
}
