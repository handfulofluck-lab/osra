package com.familyshield.agent

import com.familyshield.agent.data.WorkScheduler
import com.familyshield.agent.network.UnlinkPolicy
import java.io.File
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Issue #1073: the second `device_revoked` answer must not wait for WorkManager's ~15-minute clamp.
 *
 * `CommandPoller.onPollAnswer` is the one place both polls read the answer (the worker and the in-process
 * loop), so the follow-up is scheduled there, and only on the **first** answer — scheduling on a confirmed
 * unlink would be a poll after the phone has left the family.
 *
 * Read as text for the call site, the technique `LocationServiceStartSitesTest` uses; the semantics of the
 * policy are `UnlinkPolicyTest`.
 *
 * Mutants: drop the `pollCommandsSoon` call (row 1 red); schedule it on both branches (row 1 red); set the
 * follow-up shorter than the confirmation interval (row 2 red).
 */
class RevokedFollowUpWiringTest {

    private val poller = sourceFile("app/src/main/java/com/familyshield/agent/commands/CommandPoller.kt")

    @Test
    fun `a first revoked answer schedules the follow-up poll and a confirmed one does not`() {
        val body = poller.substring(poller.indexOf("suspend fun onPollAnswer"))
        val revoked = body.indexOf("unlinkPolicy.onDeviceRevoked(")
        val confirmed = body.indexOf("unlinker.unlink()")
        val schedule = body.indexOf("WorkScheduler.pollCommandsSoon(context)")

        assertTrue("the answer path exists", revoked >= 0 && confirmed >= 0)
        assertTrue("the follow-up is scheduled in this method", schedule > revoked)
        assertTrue(
            "scheduled only after the confirmed branch, so a confirmed unlink does not poll again",
            schedule > confirmed,
        )
    }

    @Test
    fun `the follow-up lands after the confirmation interval, or it could never confirm`() {
        assertTrue(
            "a ${WorkScheduler.REVOKED_FOLLOW_UP_MS} ms follow-up against a " +
                "${UnlinkPolicy.DEFAULT_CONFIRM_MS} ms interval would always be too soon",
            WorkScheduler.REVOKED_FOLLOW_UP_MS > UnlinkPolicy.DEFAULT_CONFIRM_MS,
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
