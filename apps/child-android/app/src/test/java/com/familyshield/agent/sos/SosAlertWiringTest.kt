package com.familyshield.agent.sos

import java.io.File
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Issue #672: [SosLocationPolicyTest] holds what a fix turns into; this class holds the wiring that makes
 * the SOS screen ask for one, and that the alert is never held up by it.
 *
 * Source-text rows, the `BlockWindowWiringTest` shape: the two ends are a Compose activity the JVM cannot
 * start and an Android location client it cannot fake. What these rows do not prove is that the phone
 * answers at all — that is the SC-1.9 handset row.
 *
 * Mutants: drop `val fix = lastKnownFix()` → [the alert carries the last fix]; drop the timeout → [the
 * alert is never held up by the fix]; drop `ACTION_PING_NOW` → [a fresh fix is requested the locate_now way];
 * drop the permission gate → the same row.
 */
class SosAlertWiringTest {

    private val sos = sourceFile("app/src/main/java/com/familyshield/agent/sos/SosActivity.kt")

    /** The body of `sendSos`, up to the KDoc of the next function. */
    private val send: String = sos.substringAfter("private fun sendSos()").substringBefore("/**")

    @Test
    fun `the alert carries the last fix`() {
        assertTrue("the SOS must ask the platform for the fix it is about to send", send.contains("val fix = lastKnownFix()"))
        assertTrue(
            "and add the five keys to the same metadata as the device id (#672)",
            send.contains("SosLocationPolicy.metadata(fix, sentAtMs)") &&
                send.contains("mapOf(\"deviceId\" to (deviceId ?: \"\"))"),
        )
    }

    @Test
    fun `the alert is never held up by the fix`() {
        assertTrue(
            "a location task that does not answer must not delay the alert past the parent's 10 s budget",
            sos.contains("withTimeoutOrNull(LAST_FIX_WAIT_MS)") && sos.contains("LAST_FIX_WAIT_MS: Long = 1_500L"),
        )
    }

    @Test
    fun `a fresh fix is requested the locate_now way`() {
        assertTrue(
            "LocationService takes one high-accuracy fix and flushes it as a ping (the locate_now path)",
            sos.contains("LocationService.ACTION_PING_NOW") && sos.contains("ContextCompat.startForegroundService"),
        )
        assertTrue(
            "and the start is gated on SOS-fresh-fix rules: no location grant kills the process (#128/#132), " +
                "an unpaired phone has nobody to show the ping to (#672 review, Fable note 1)",
            sos.contains(
                "if (!SosFreshFixPolicy.shouldRequest(settings.isPairedSync(), hasLocationPermission())) return",
            ),
        )
    }

    private fun sourceFile(relative: String): String {
        var dir: File? = File(System.getProperty("user.dir")).absoluteFile
        while (dir != null) {
            val candidate = File(dir, relative)
            if (candidate.isFile) return candidate.readText()
            dir = dir.parentFile
        }
        throw AssertionError("could not find $relative from ${System.getProperty("user.dir")}")
    }
}
