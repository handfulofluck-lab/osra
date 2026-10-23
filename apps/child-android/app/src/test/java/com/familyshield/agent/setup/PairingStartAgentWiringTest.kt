package com.familyshield.agent.setup

import java.io.File
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Claude's #322 phone row (2026-10-23): after a re-pair the push token stayed on the OLD device row.
 * A command to the new row woke nothing, and a command to the old row still woke the phone, until the
 * next poll ran and `CommandPoller` uploaded the token for the new device id.
 *
 * Cause: `WorkScheduler.scheduleAll` enqueues the periodic poll with `KEEP`, so on a re-pair the
 * existing schedule is kept and no poll runs at pairing time (a first pairing is fine only because a
 * newly enqueued periodic worker runs at once). The fix is one immediate fetch in `startAgent()`, the
 * function every successful claim calls right after `savePairing`.
 *
 * Source check, like [com.familyshield.agent.services.FirebaseMessagingSvcWiringTest]: the activity
 * cannot run in a JVM test. Out of reach here: that the token really moves on a device, which is the
 * hardware row.
 */
class PairingStartAgentWiringTest {

    private val source by lazy {
        sourceFile("app/src/main/java/com/familyshield/agent/setup/PairingActivity.kt").readText()
    }

    /**
     * Mutant: delete `CommandPollWorker.requestFetchNow(this)` from `startAgent()` and this fails with
     * `startAgent() must run an immediate command poll`.
     */
    @Test
    fun `startAgent runs an immediate command poll so a re-pair moves the push token at once`() {
        val body = source
            .substringAfter("private fun startAgent() {")
            .substringBefore("\n    }")

        assertTrue(
            "startAgent() must run an immediate command poll (CommandPollWorker.requestFetchNow). " +
                "The poll uploads the push token for the new device id; the periodic poll is KEEP, so " +
                "on a re-pair nothing else runs it and the token stays on the old row until the next " +
                "~15-minute poll (#322 phone row).",
            body.contains("CommandPollWorker.requestFetchNow(this)"),
        )
    }

    /**
     * Mutant: move `startAgent()` out of the claim's `onSuccess` (or drop the call) and this fails.
     * The fetch only helps if it runs on every successful claim, after the new pairing is saved.
     */
    @Test
    fun `every successful claim saves the pairing and then starts the agent`() {
        val onSuccess = source
            .substringAfter("result.onSuccess { pairing ->")
            .substringBefore("}.onFailure")
        val save = onSuccess.indexOf("settings.savePairing(")
        val start = onSuccess.indexOf("startAgent()")

        assertTrue("the claim's onSuccess must save the pairing", save >= 0)
        assertTrue(
            "the claim's onSuccess must call startAgent() after savePairing, so the immediate poll " +
                "runs with the new device id and token",
            start > save,
        )
    }

    private fun sourceFile(relative: String): File {
        var dir: File? = File(System.getProperty("user.dir") ?: ".").absoluteFile
        while (dir != null) {
            val candidate = File(dir, relative)
            if (candidate.isFile) return candidate
            dir = dir.parentFile
        }
        throw AssertionError("could not find $relative from ${System.getProperty("user.dir")}")
    }
}
