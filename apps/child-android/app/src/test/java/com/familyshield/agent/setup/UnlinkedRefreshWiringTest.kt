package com.familyshield.agent.setup

import com.familyshield.agent.network.DeviceUnlinker
import java.io.File
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Issue #471: after an unlink the status screen kept saying "device admin: on" and "web filter:
 * connected" until the activity was recreated, while `dumpsys` already reported both gone. The unlink
 * runs in the agent, so the screen has to be told.
 *
 * **Why a source-text row.** This is lifecycle wiring inside an `Activity` that a plain JVM test
 * cannot start (no Robolectric in this module), and the interesting part is not a pure decision — it is
 * that the two halves are connected at all. The shape follows `CommsGrantWiringTest` and
 * `LocationServiceStartSitesTest`: assert the contract names exist at both ends, so deleting one end
 * fails here instead of failing silently on a phone.
 *
 * **What it does not prove:** that a broadcast actually re-renders the screen on a device. That is the
 * hardware row's job (the Flip4, with the status screen in the foreground), and the PR says so.
 *
 * Mutants: remove `sendBroadcast` from `DeviceUnlinker.unlink()` → [unlink announces itself]; remove
 * the `registerReceiver` call → [the status screen listens while it is started].
 */
class UnlinkedRefreshWiringTest {

    private val unlinker = sourceFile("app/src/main/java/com/familyshield/agent/network/DeviceUnlinker.kt")
    private val pairing = sourceFile("app/src/main/java/com/familyshield/agent/setup/PairingActivity.kt")

    @Test
    fun `the broadcast action is one constant, not two literals`() {
        assertEquals("com.familyshield.agent.action.UNLINKED", DeviceUnlinker.ACTION_UNLINKED)
        assertTrue(
            "PairingActivity must reference the constant, or a rename breaks the refresh silently",
            pairing.contains("DeviceUnlinker.ACTION_UNLINKED"),
        )
        assertEquals(
            "the activity must not repeat the literal: a rename would leave one end pointing at nothing",
            pairing.split("com.familyshield.agent.action.UNLINKED").size - 1,
            0,
        )
    }

    @Test
    fun `unlink announces itself after the sequence, package-scoped`() {
        assertTrue(unlinker.contains("sendBroadcast(Intent(ACTION_UNLINKED)"))
        assertTrue(
            "a package-scoped broadcast cannot leave the app",
            unlinker.contains(".setPackage(context.packageName)"),
        )
        // The announcement must follow the steps: a notice that fires first would say "unlinked"
        // while the admin grant was still in place.
        assertTrue(
            unlinker.indexOf("sendBroadcast") > unlinker.indexOf("runUnlinkSteps("),
        )
    }

    @Test
    fun `the status screen listens while it is started and re-reads the pair state`() {
        assertTrue(pairing.contains("IntentFilter(DeviceUnlinker.ACTION_UNLINKED)"))
        assertTrue(pairing.contains("RECEIVER_NOT_EXPORTED"))
        assertTrue("registered for started, not created", pairing.contains("override fun onStart()"))
        assertTrue("and released, so it cannot leak", pairing.contains("unregisterReceiver(unlinkedReceiver)"))
        assertTrue(
            "the screen re-renders from the pair state rather than trusting the broadcast payload",
            pairing.contains("if (!settings.isPaired()) showForm("),
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
