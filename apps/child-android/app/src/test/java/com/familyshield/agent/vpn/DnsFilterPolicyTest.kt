package com.familyshield.agent.vpn

import com.familyshield.agent.vpn.DnsFilterPolicy.Action
import com.familyshield.agent.vpn.DnsFilterPolicy.Config
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/** Plan 1.4: the sinkhole's decision table. */
class DnsFilterPolicyTest {

    @Test
    fun `nothing configured forwards everything`() {
        assertEquals(Action.FORWARD, DnsFilterPolicy.decide("example.com", Config()).action)
        assertEquals(Action.FORWARD, DnsFilterPolicy.decide("www.google.com", Config()).action)
        assertEquals(Action.FORWARD, DnsFilterPolicy.decide("www.youtube.com", Config(youtubeMode = "off")).action)
    }

    @Test
    fun `blocked domain sinks itself and its subdomains, not look-alikes`() {
        val c = Config(blockedDomains = listOf("Blocked.example."))
        assertEquals(Action.SINK, DnsFilterPolicy.decide("blocked.example", c).action)
        assertEquals(Action.SINK, DnsFilterPolicy.decide("WWW.blocked.example.", c).action)
        assertEquals(Action.FORWARD, DnsFilterPolicy.decide("notblocked.example", c).action)
        assertEquals("blocked_domain:blocked.example", DnsFilterPolicy.decide("a.blocked.example", c).reason)
    }

    @Test
    fun `category domains from the pack sink with the category as reason`() {
        val c = Config(categoryDomains = mapOf("*.gambling.example" to "Gambling"))
        val d = DnsFilterPolicy.decide("play.gambling.example", c)
        assertEquals(Action.SINK, d.action)
        assertEquals("category:gambling", d.reason)
    }

    @Test
    fun `allowed domain beats blocked domain, category, safesearch and youtube`() {
        val c = Config(
            safeSearch = true, youtubeMode = "strict",
            allowedDomains = listOf("www.youtube.com", "blocked.example", "google.com"),
            blockedDomains = listOf("blocked.example"),
            categoryDomains = mapOf("blocked.example" to "x"),
        )
        assertEquals(Action.FORWARD, DnsFilterPolicy.decide("www.blocked.example", c).action)
        assertEquals(Action.FORWARD, DnsFilterPolicy.decide("www.youtube.com", c).action)
        assertEquals(Action.FORWARD, DnsFilterPolicy.decide("www.google.com", c).action)
    }

    @Test
    fun `pause-internet sinks everything including allowed domains`() {
        val c = Config(pausedInternet = true, allowedDomains = listOf("school.example"))
        assertEquals(Action.SINK, DnsFilterPolicy.decide("school.example", c).action)
        assertEquals("paused_internet", DnsFilterPolicy.decide("anything.example", c).reason)
    }

    @Test
    fun `safesearch rewrites the search engines to their enforcement hosts`() {
        val c = Config(safeSearch = true)
        assertEquals("forcesafesearch.google.com", DnsFilterPolicy.decide("www.google.com", c).target)
        assertEquals("forcesafesearch.google.com", DnsFilterPolicy.decide("google.co.uk", c).target)
        assertEquals("forcesafesearch.google.com", DnsFilterPolicy.decide("www.google.ae", c).target)
        assertEquals("strict.bing.com", DnsFilterPolicy.decide("www.bing.com", c).target)
        assertEquals("safe.duckduckgo.com", DnsFilterPolicy.decide("duckduckgo.com", c).target)
        // not search hosts
        assertEquals(Action.FORWARD, DnsFilterPolicy.decide("mail.google.com", c).action)
        assertEquals(Action.FORWARD, DnsFilterPolicy.decide("googleapis.com", c).action)
        assertEquals(Action.FORWARD, DnsFilterPolicy.decide("www.googleadservices.com", c).action)
        // the enforcement hosts themselves are never touched (no rewrite loop)
        assertEquals(Action.FORWARD, DnsFilterPolicy.decide("forcesafesearch.google.com", c).action)
    }

    @Test
    fun `youtube restricted mode rewrites the youtube hosts, strict or moderate`() {
        val strict = Config(youtubeMode = "strict")
        val moderate = Config(youtubeMode = "Moderate")
        for (h in listOf("www.youtube.com", "m.youtube.com", "youtubei.googleapis.com", "youtube.googleapis.com", "www.youtube-nocookie.com")) {
            assertEquals(h, "restrict.youtube.com", DnsFilterPolicy.decide(h, strict).target)
            assertEquals(h, "restrictmoderate.youtube.com", DnsFilterPolicy.decide(h, moderate).target)
        }
        assertEquals(Action.FORWARD, DnsFilterPolicy.decide("restrict.youtube.com", strict).action)
        assertEquals(Action.FORWARD, DnsFilterPolicy.decide("i.ytimg.com", strict).action)
        assertEquals(Action.FORWARD, DnsFilterPolicy.decide("www.youtube.com", Config(youtubeMode = "off")).action)
    }

    @Test
    fun `a blocked domain also sinks the enforcement host it points at (#825, Fable B1)`() {
        val youtubeBlocked = Config(youtubeMode = "strict", blockedDomains = listOf("youtube.com"))
        assertEquals(Action.SINK, DnsFilterPolicy.decide("restrict.youtube.com", youtubeBlocked).action)
        assertEquals(Action.SINK, DnsFilterPolicy.decide("restrictmoderate.youtube.com", youtubeBlocked).action)
        assertEquals(Action.SINK, DnsFilterPolicy.decide("forcesafesearch.google.com", Config(safeSearch = true, blockedDomains = listOf("google.com"))).action)
        assertEquals(Action.SINK, DnsFilterPolicy.decide("strict.bing.com", Config(safeSearch = true, blockedDomains = listOf("bing.com"))).action)
        // With nothing blocked the enforcement hosts are still forwarded.
        assertEquals(Action.FORWARD, DnsFilterPolicy.decide("restrict.youtube.com", Config(youtubeMode = "strict")).action)
        assertEquals(Action.FORWARD, DnsFilterPolicy.decide("forcesafesearch.google.com", Config(safeSearch = true)).action)
    }

    @Test
    fun `an explicit blocked domain sinks before the youtube or safesearch rewrite (#825)`() {
        val c = Config(
            safeSearch = true,
            youtubeMode = "strict",
            blockedDomains = listOf("youtube.com", "google.com", "bing.com"),
        )
        assertEquals(Action.SINK, DnsFilterPolicy.decide("www.youtube.com", c).action)
        assertEquals(Action.SINK, DnsFilterPolicy.decide("m.youtube.com", c).action)
        assertEquals("blocked_domain:youtube.com", DnsFilterPolicy.decide("www.youtube.com", c).reason)
        assertEquals(Action.SINK, DnsFilterPolicy.decide("www.google.com", c).action)
        assertEquals(Action.SINK, DnsFilterPolicy.decide("www.bing.com", c).action)
        // The rest of the rewrite still works for everything the parent did not block.
        assertEquals("restrict.youtube.com", DnsFilterPolicy.decide("youtubei.googleapis.com", c).target)
        assertEquals("forcesafesearch.google.com", DnsFilterPolicy.decide("google.ae", c).target)
    }

    @Test
    fun `safesearch off leaves the engines alone even with youtube strict`() {
        val c = Config(safeSearch = false, youtubeMode = "strict")
        assertEquals(Action.FORWARD, DnsFilterPolicy.decide("www.google.com", c).action)
        assertEquals(Action.REWRITE, DnsFilterPolicy.decide("www.youtube.com", c).action)
    }

    @Test
    fun `google search host detection`() {
        assertTrue(DnsFilterPolicy.isGoogleSearchHost("google.com"))
        assertTrue(DnsFilterPolicy.isGoogleSearchHost("www.google.com.au"))
        assertTrue(DnsFilterPolicy.isGoogleSearchHost("google.de"))
        assertFalse(DnsFilterPolicy.isGoogleSearchHost("accounts.google.com"))
        assertFalse(DnsFilterPolicy.isGoogleSearchHost("google.example.com"))
        assertFalse(DnsFilterPolicy.isGoogleSearchHost("notgoogle.com"))
    }

    @Test
    fun `blank and dotted names normalise`() {
        assertEquals(Action.FORWARD, DnsFilterPolicy.decide("", Config(pausedInternet = true)).action)
        assertEquals("example.com", DnsFilterPolicy.normalize(" *.Example.COM. "))
    }

    @Test
    fun `doh bypass and canary hosts sink when filtering is active so incognito uses vpn dns`() {
        val active = Config(categoryDomains = mapOf("pornhub.com" to "pornography"))
        for (host in listOf("use-application-dns.net", "dns.google", "cloudflare-dns.com", "dns.quad9.net")) {
            val d = DnsFilterPolicy.decide(host, active)
            assertEquals("$host must sink when filtering active", Action.SINK, d.action)
            assertEquals(DnsFilterPolicy.REASON_DOH_BYPASS, d.reason)
        }
        // Inactive filter forwards normally; explicit allow overrides.
        assertEquals(Action.FORWARD, DnsFilterPolicy.decide("dns.google", Config()).action)
        assertEquals(
            Action.FORWARD,
            DnsFilterPolicy.decide("dns.google", active.copy(allowedDomains = listOf("dns.google"))).action,
        )
    }
}
