package com.familyshield.agent.vpn

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * #830 gating: the two off-state rows Fable asked for, plus the exclusion and the flag-on control.
 * These are the mutants the verifier should plant: ignoring `siteNamesEnabled` on the phone (row 1
 * turns green) and ignoring `blocked` (row 2 turns red).
 */
class SiteVisitGateTest {

    @Test
    fun `flag off keeps an unblocked name on the phone`() {
        assertFalse(SiteVisitGate.shouldUpload(siteNamesEnabled = false, blocked = false))
    }

    @Test
    fun `a blocked attempt is behind the flag too (Fable, blocker A)`() {
        // The alert is the hostless count; the activity stream carries no name while the flag is off.
        assertFalse(SiteVisitGate.shouldUpload(siteNamesEnabled = false, blocked = true))
    }

    @Test
    fun `flag on uploads an unblocked name`() {
        assertTrue(SiteVisitGate.shouldUpload(siteNamesEnabled = true, blocked = false))
    }

    @Test
    fun `an excluded host never uploads`() {
        assertFalse(SiteVisitGate.shouldUpload(siteNamesEnabled = true, blocked = true, excludedHost = true))
    }

    @Test
    fun `the phone drops the same hosts the server drops`() {
        for (host in listOf(
            "api.osratech.com",
            "osratech.com",
            "forcesafesearch.google.com",
            "strict.bing.com",
            "restrict.youtube.com",
            "connectivitycheck.gstatic.com",
            "time.android.com",
            "use-application-dns.net",
            "dns.google",
            "",
        )) {
            assertTrue("$host should be excluded", SiteVisitGate.isExcludedHost(host))
        }
        for (host in listOf("example.com", "notosratech.com", "youtube.com")) {
            assertFalse("$host should not be excluded", SiteVisitGate.isExcludedHost(host))
        }
    }

    @Test
    fun `a DNS name is matched after its trailing dot and case are normalised`() {
        assertTrue(SiteVisitGate.isExcludedHost("API.OSRATECH.COM."))
        assertFalse(SiteVisitGate.isExcludedHost("Example.COM."))
    }
}
