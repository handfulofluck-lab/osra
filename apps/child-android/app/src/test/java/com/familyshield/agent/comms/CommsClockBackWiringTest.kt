package com.familyshield.agent.comms

import java.io.File
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Issue #513, the wiring half: the policy is tested in [CommsFutureSmsPolicyTest], but a policy nobody calls
 * changes nothing. `harvestSms` is in the `full` flavour and needs a ContentProvider, so what is pinned here
 * is the order of the statements in the clock-back branch — the part that made the duplicate possible.
 *
 * Mutants: move the `setFutureSmsSeen` call after the watermark write and
 * [the remembered rows are written before the watermark moves] goes red; delete the call and
 * [the clock-back branch remembers what the forward clock read] goes red.
 */
class CommsClockBackWiringTest {

    private val logger = sourceFile("app/src/full/java/com/familyshield/agent/comms/CommsLogger.kt")

    @Test
    fun `the clock-back branch remembers what the forward clock read`() {
        val branch = clockBackBranch()
        assertTrue(
            "the branch must build the entries from the rows the forward clock had read",
            branch.contains("CommsFutureSmsPolicy.seenOnClockBack("),
        )
        assertTrue(
            "and persist them, or the next harvest imports the same text again",
            branch.contains("settings.setFutureSmsSeen("),
        )
        assertTrue(
            "the rows come from the window between now and the watermark that was in the future",
            branch.contains("smsRowsBetween(now, ceiling)"),
        )
    }

    @Test
    fun `the remembered rows are written before the watermark moves`() {
        // A crash between the two costs one duplicate guard at worst, never a message — but only in this
        // order. Written the other way round, the watermark has already moved when the set is missing.
        val branch = clockBackBranch()
        val remembered = branch.indexOf("settings.setFutureSmsSeen(")
        val reanchored = branch.indexOf("dao.set(AgentStateEntity(KEY_SMS_WATERMARK, now))")
        assertTrue("both statements must be in the branch", remembered >= 0 && reanchored >= 0)
        assertTrue("the set is written first, the watermark second", remembered < reanchored)
    }

    /** The text of the `isClockBack` branch, up to its `return@withLock`. */
    private fun clockBackBranch(): String {
        val start = logger.indexOf("if (CommsWatermarkPolicy.isClockBack(stored, now))")
        assertTrue("the clock-back branch must exist", start > 0)
        val end = logger.indexOf("return@withLock", start)
        assertTrue("the branch must return without reading", end > start)
        return logger.substring(start, end)
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
