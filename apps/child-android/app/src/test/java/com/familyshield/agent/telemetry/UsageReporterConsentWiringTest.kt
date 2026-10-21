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
    fun `our own window ends the interval without moving what is open`() {
        // Issue #284: the block screen is a window this stream never records, so the blocked app's
        // interval stayed open. The seam is the source text, not a fake DAO: UsageReporter needs an
        // Android Context and the concrete Room database, so this class cannot be instantiated here
        // (the reason this file exists at all). What a green run means: the interval is ended, the
        // gap-closing event is written, and neither `lastPkg` nor the unlock count is touched -- the
        // lock overlay's "what is open now" must keep naming the app behind the overlay.
        val body = reporter.substringAfter("fun recordOwnWindow(").substringBefore("suspend fun aggregateAndUpload")
        val pauseCheck = body.indexOf("if (consent.isPaused()) return")
        val end = body.indexOf("rules.onForegroundEnded")
        val insert = body.indexOf("db.usageEventDao().insert")
        assertTrue("nothing is collected while consent is withdrawn", pauseCheck >= 0)
        assertTrue("the daily counter is not advanced before the pause check", pauseCheck < end)
        assertTrue("and neither is the telemetry event", pauseCheck < insert)
        assertTrue("the gap closes for the counters", end >= 0)
        assertTrue(
            "the event names our own package, so the upload path sees the window too",
            body.contains("UsageEventEntity(packageId = own, timestamp = ts)"),
        )
        assertFalse("the app in front is still the blocked app", body.contains("lastPkg ="))
        assertFalse("waiting on a block screen is not a new session", body.contains("unlockCounter"))
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
    fun `the backfill is a delta, and a re-grant resets its baseline instead of skipping`() {
        val body = reporter.substringAfter("private fun backfillFromUsageStats").substringBefore("companion object")
        // #267: the whole-day totals are counters now, so an app absent from this window adds only its
        // increase. Adding the total is what over-counted every family with usage access.
        assertTrue(
            "each package's increase is judged against the rollover decision",
            body.contains("UsageStatsDelta.deltaForUpload(total, lastSeen[pkg], rollover, hasSnapshot)"),
        )
        // #272 review D3: a moved bucket key is not a rollover on its own -- a clock change shifts the
        // key and leaves the counters alone, so the counters decide.
        assertTrue("the rollover decision is the policy's", body.contains("UsageStatsDelta.isRollover(storedBucket, bucketBegin, lastSeen, totals)"))
        // And an empty query must not record a snapshot keyed 0: that would baseline nothing and send
        // whole totals on the next upload.
        assertTrue("an empty query records nothing", body.contains("if (stats.isEmpty()) return null"))
        assertTrue("every package's total is recorded, not only the ones added", body.contains("settings.setUsageStatsSnapshot(bucketBegin, totals)"))
        // #272 review: the snapshot must be keyed by Android's own bucket, not the calendar date — the
        // phone rolls it at 20:07, so a date key re-sent up to four hours every morning.
        assertFalse("a calendar-date key is the bug", body.contains("LocalDate.now().toString()"))
        assertFalse(
            "the whole-day total is the bug: it was added on every upload",
            body.contains("perApp[s.packageName] = minutes"),
        )
        assertFalse(
            "and #266's skip is replaced by the baseline, not kept beside it",
            body.contains("if (consent.resumedAtMs() > startOfDay) return"),
        )
        // The re-grant baseline lives in aggregateAndUpload's reset block.
        val reset = reporter.substringAfter("CommsConsentPolicy.resetTo(").substringBefore("if (consent.isPaused())")
        assertTrue(
            "a re-grant excludes what Android has already counted instead of uploading it",
            reset.contains("usageStatsTotals()?.let { (bucketBegin, totals) -> settings.setUsageStatsSnapshot(bucketBegin, totals) }"),
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
