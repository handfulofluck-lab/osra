package com.familyshield.agent

import java.io.File
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * #830: the three reporting call sites exist where the triage put them. The behaviour is covered by the
 * server tests and the pure helpers; this pins the wiring so a refactor cannot drop a report silently.
 */
class Reporting830WiringTest {

    @Test
    fun `a block reports its attempt, a dns sink reports the site, and a lock has a period`() {
        val block = source("apps/child-android/app/src/main/java/com/familyshield/agent/enforcement/BlockActivity.kt")
        assertTrue(block.contains("reportBlockedAttempt(request.packageId"))
        assertTrue(block.contains("dedupeKey = AlertKeys.blockedApp"))

        val vpn = source("apps/child-android/app/src/main/java/com/familyshield/agent/vpn/FilterVpnService.kt")
        assertTrue(vpn.contains("reportBlockedSite(q.name"))
        assertTrue(vpn.contains("AlertKeys.blockedSite"))
        // #841: the exclusion check must be at the call site, not only inside the helper, and the name
        // must be normalised once so two spellings of a host cannot split the maps.
        // #841: the call sites are part of the feature — the fold of #836 dropped both and every row
        // stayed green, so these two lines are pinned here, not only the text inside the function.
        assertTrue(vpn.contains("recordSiteVisit(q.name, blocked = false)"))
        assertTrue(vpn.contains("recordSiteVisit(q.name, blocked = true)"))
        assertTrue(vpn.contains("SiteVisitGate.shouldUpload(config.siteNamesEnabled, blocked, SiteVisitGate.isExcludedHost(name))"))
        assertTrue(vpn.contains("DnsFilterPolicy.normalize(host)"))
        // #841 review: the alert path normalises too, one flusher wins the race, and a drained batch is
        // sent whole (up to the API's 200) instead of being truncated after the queue was cleared.
        val alert = vpn.substringAfter("private fun reportBlockedSite").substringBefore("private fun recordSiteVisit")
        assertTrue(alert.contains("val name = DnsFilterPolicy.normalize(host)"))
        assertTrue(alert.contains("SiteVisitGate.isExcludedHost(name)"))
        assertTrue(vpn.contains("visitFlusherStarted.compareAndSet(false, true)"))
        assertTrue(vpn.contains("events = batch.map {"))
        // Claude's finding-5 ruling on #841: while the flag is off the alert is a count with no host.
        val blockedSite = vpn.substringAfter("private fun reportBlockedSite").substringBefore("private fun recordSiteVisit")
        // Blocker D's shape: one config read, the hostless key, and no rule-store read inside the alert.
        assertTrue(blockedSite.contains("val siteNames = config.siteNamesEnabled"))
        assertTrue(blockedSite.contains("\"blocked-day\""))
        assertTrue(blockedSite.contains("\"web:\$day\""))
        assertFalse(blockedSite.contains("rules.siteNamesEnabled()"))

        val dispatcher = source("apps/child-android/app/src/main/java/com/familyshield/agent/commands/CommandDispatcher.kt")
        assertTrue(dispatcher.contains("LockPeriodTracker.start(context, LockActivity.MODE_LOCKED"))
        assertTrue(dispatcher.contains("LockPeriodTracker.start(context, LockActivity.MODE_PAUSED_INTERNET"))
        assertTrue(dispatcher.contains("LockPeriodTracker.end(context)"))
        assertTrue(dispatcher.contains("type = \"lock_period\""))
    }

    /**
     * Hydrogen's #836 blockers: the two reporting call sites a `singleTask` reuse and the resume path
     * skipped. The behaviour rows are the server's; these pin that the screens and commands call them.
     */
    @Test
    fun `a reused block screen reports its attempt, and resume_internet closes its period`() {
        val block = source("apps/child-android/app/src/main/java/com/familyshield/agent/enforcement/BlockActivity.kt")
        val onNewIntent = block.substringAfter("override fun onNewIntent(intent: Intent)").substringBefore("private fun applyIntent")
        assertTrue("onNewIntent must report the attempt", onNewIntent.contains("reportBlockedAttempt(request.packageId"))

        val dispatcher = source("apps/child-android/app/src/main/java/com/familyshield/agent/commands/CommandDispatcher.kt")
        val resume = dispatcher.substringAfter("private fun resumeInternet()").substringBefore("Wind-down (Feature #22)")
        assertTrue("resume_internet must close the paused period", resume.contains("LockPeriodTracker.end(context)"))
    }

    private fun source(relative: String): String {
        var dir: File? = File(System.getProperty("user.dir") ?: ".").absoluteFile
        while (dir != null) {
            val candidate = File(dir, relative)
            if (candidate.isFile) return candidate.readText()
            dir = dir.parentFile
        }
        throw AssertionError("not found from ${System.getProperty("user.dir")}: $relative")
    }
}
