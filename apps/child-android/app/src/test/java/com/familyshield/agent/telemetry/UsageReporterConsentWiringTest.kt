package com.familyshield.agent.telemetry

import java.io.File
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Issue #265: screen-time telemetry kept collecting while consent was withdrawn, then uploaded the
 * paused window after the re-grant as "today's screen time".
 *
 * The decision itself is [com.familyshield.agent.comms.CommsConsentPolicy], already held by five JVM
 * cases. This pins the *wiring*, because `UsageReporter` needs Android, Room and an injected service
 * and cannot run in this suite (no Robolectric, no `androidTest` source set here — the same reasoning
 * as [com.familyshield.agent.comms.CommsGrantWiringTest]).
 *
 * What a green run means: each of the four sites reads the consent state at the decision point. What
 * it does not mean: that a withdrawal actually stops the accessibility stream on a phone. That row is
 * Claude's, on the Flip4.
 */
class UsageReporterConsentWiringTest {

    private val reporter = sourceFile("app/src/main/java/com/familyshield/agent/telemetry/UsageReporter.kt")

    @Test
    fun `live activity is not posted while consent is withdrawn`() {
        val block = reporter.substringAfter("suspend fun postLiveActivity()")
        val body = block.substringBefore("fun currentForeground")
        val pauseCheck = body.indexOf("if (consent.isPaused()) return")
        val post = body.indexOf("api.postActivityEvents")
        assertTrue("postLiveActivity must read the consent flag", pauseCheck >= 0)
        assertTrue("and return before it posts the foreground app", pauseCheck < post)
    }

    @Test
    fun `a 428 on live activity is not logged as a warning`() {
        val block = reporter.substringAfter("suspend fun postLiveActivity()")
        val body = block.substringBefore("fun currentForeground")
        assertTrue(
            "a withdrawal racing the post is the expected answer, not a stack",
            body.contains("ConsentPolicy.httpStatusOf(e) == 428"),
        )
        assertTrue("every other failure still logs with its exception", body.contains("Log.w(TAG, \"live activity post failed\", e)"))
    }

    @Test
    fun `a foreground change stops counting while paused but still tracks what is open`() {
        val body = reporter.substringAfter("fun recordForeground(").substringBefore("suspend fun aggregateAndUpload")
        val tracks = body.indexOf("lastPkg = pkg")
        val pauseCheck = body.indexOf("if (consent.isPaused()) return")
        val counters = body.indexOf("rules.onForegroundEvent")
        val insert = body.indexOf("usageEventDao().insert")
        val unlock = body.indexOf("unlockCounter.incrementAndGet()")
        // #266 review D1: `rules.onForegroundEvent` is the daily minute counter, not enforcement -- the
        // rule engine returns ALLOW while paused anyway. It must sit *after* the pause check, or the
        // withdrawn window is credited to the open app and reported as today's total after the re-grant.
        assertTrue("the open package is still tracked for the overlay", tracks in 0 until pauseCheck)
        assertTrue("the pause check comes before the minute counter", pauseCheck < counters)
        assertTrue("and before the Room insert", pauseCheck < insert)
        assertTrue("and before the unlock count", pauseCheck < unlock)
    }

    @Test
    fun `a re-grant restarts the window at the moment the phone learned consent came back`() {
        assertTrue(
            "the reset decision is reused, not copied",
            reporter.contains("CommsConsentPolicy.resetTo("),
        )
        assertTrue("the watermark restarts from the re-grant", reporter.contains("stateDao.set(AgentStateEntity(KEY_WATERMARK, restartFrom))"))
        assertTrue("events from the paused window are dropped", reporter.contains("dao.deleteOlderThan(restartFrom)"))
        assertTrue("the paused-window unlocks are dropped with them", reporter.contains("unlockCounter.set(0)"))
        assertTrue("and the epoch is recorded so the reset runs once", reporter.contains("KEY_CONSENT_EPOCH, epoch"))
    }

    @Test
    fun `the UsageStats backfill is skipped on a re-grant day`() {
        val body = reporter.substringAfter("private fun backfillFromUsageStats").substringBefore("companion object")
        val startOfDay = body.indexOf("startOfDay =")
        val skip = body.indexOf("if (consent.resumedAtMs() > startOfDay) return")
        val query = body.indexOf("queryUsageStats")
        // #266 review D2: queryUsageStats returns whole day buckets, and a paused device writes no rows,
        // so an app used only during the withdrawal would be backfilled with its whole-day total.
        assertTrue("the skip must exist", skip >= 0)
        assertTrue("and run before the query", startOfDay < skip && skip < query)
        assertFalse(
            "a floor inside the day does not exclude the bucket, so it is not the fix",
            body.contains("maxOf(startOfDay"),
        )
    }

    @Test
    fun `the telemetry epoch is its own key, so the comms reset cannot clear it`() {
        assertTrue(reporter.contains("\"telemetry_consent_epoch\""))
        assertFalse("a shared key would make one stream reset the other", reporter.contains("\"comms_consent_epoch\""))
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
