package com.familyshield.agent

import java.io.File
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

        val dispatcher = source("apps/child-android/app/src/main/java/com/familyshield/agent/commands/CommandDispatcher.kt")
        assertTrue(dispatcher.contains("LockPeriodTracker.start(context, LockActivity.MODE_LOCKED"))
        assertTrue(dispatcher.contains("LockPeriodTracker.start(context, LockActivity.MODE_PAUSED_INTERNET"))
        assertTrue(dispatcher.contains("LockPeriodTracker.end(context)"))
        assertTrue(dispatcher.contains("type = \"lock_period\""))
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
