package com.familyshield.agent.enforcement

import java.io.File
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Issue #488 (Flip4, #484 rows): a block screen left open across an unlink still said "This app is
 * blocked by your parent", on a phone no family manages any more. Only `PairingActivity` heard
 * `DeviceUnlinker.ACTION_UNLINKED`.
 *
 * Source-text rows, the `UnlinkedRefreshWiringTest` shape: this is lifecycle wiring inside activities a
 * plain JVM test cannot start, and the point is that both ends are connected at all. What it does not
 * prove is that a real broadcast closes a real screen; that is the K2 phone row on #484.
 *
 * Mutants: drop the block screen's `registerReceiver` → [the block screen listens while it is started];
 * drop its `onResume` branch → [the block screen closes on return when the phone is unpaired]; drop the
 * lock screen's `registerReceiver` → [the lock screen listens while it is started].
 */
class UnlinkedOverlayWiringTest {

    private val block = sourceFile("app/src/main/java/com/familyshield/agent/enforcement/BlockActivity.kt")
    private val lock = sourceFile("app/src/main/java/com/familyshield/agent/commands/LockActivity.kt")
    private val unlinker = sourceFile("app/src/main/java/com/familyshield/agent/network/DeviceUnlinker.kt")

    @Test
    fun `the block screen listens while it is started and closes when the phone is unpaired`() {
        val onStart = block.substringAfter("override fun onStart()").substringBefore("override fun onStop()")
        assertTrue("registered for started", onStart.contains("IntentFilter(DeviceUnlinker.ACTION_UNLINKED)"))
        assertTrue("and never exported", onStart.contains("RECEIVER_NOT_EXPORTED"))
        assertTrue("released, so it cannot leak", block.contains("unregisterReceiver(unlinkedReceiver)"))
        val receiver = block.substringAfter("private val unlinkedReceiver").substringBefore("override fun onStart()")
        assertTrue(
            "the receiver re-reads the pair state rather than trusting the broadcast",
            receiver.contains("if (!settings.isPairedSync()) finish()"),
        )
    }

    @Test
    fun `the block screen closes on return when the phone is unpaired`() {
        val onResume = block.substringAfter("override fun onResume()").substringBefore("/**")
        assertTrue(
            "an unlink while the screen was in the background is caught on return",
            onResume.contains("if (!settings.isPairedSync()) finish()"),
        )
    }

    @Test
    fun `the lock screen listens while it is started and closes once the lock is cleared`() {
        val onStart = lock.substringAfter("override fun onStart()").substringBefore("override fun onStop()")
        assertTrue("registered for started", onStart.contains("IntentFilter(DeviceUnlinker.ACTION_UNLINKED)"))
        assertTrue("and never exported", onStart.contains("RECEIVER_NOT_EXPORTED"))
        assertTrue("released, so it cannot leak", lock.contains("unregisterReceiver(unlinkedReceiver)"))
        val receiver = lock.substringAfter("private val unlinkedReceiver").substringBefore("override fun onStart()")
        assertTrue(
            "the receiver re-reads LockState rather than trusting the broadcast",
            receiver.contains("if (!LockState.isActive(this@LockActivity)) finish()"),
        )
    }

    /**
     * The lock screen's background path is the one it already had (#233 F2): `onResume` finishes when
     * [LockState] no longer holds a locking mode. That covers an unlink only because the unlink clears
     * the lock, so both ends are pinned here.
     */
    @Test
    fun `the lock screen's return path holds because the unlink clears the lock`() {
        assertTrue("the unlink clears the stored lock", unlinker.contains("clearLock = { LockState.clear(context) }"))
        val onResume = lock.substringAfter("override fun onResume()").substringBefore("override fun onUserLeaveHint()")
        assertTrue(
            "and onResume finishes when the stored mode no longer shows",
            onResume.contains("if (decision !is LockScreenPolicy.Decision.Show) finish()"),
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
