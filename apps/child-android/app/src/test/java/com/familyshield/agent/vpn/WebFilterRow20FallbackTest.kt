package com.familyshield.agent.vpn

import java.io.File
import kotlinx.coroutines.runBlocking
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class WebFilterRow20FallbackTest {

    @After
    fun tearDown() {
        WebFilterRow20Fallback.setOverrideForTest(null)
    }

    @Test
    fun `default switches are off and preserve 1s reset hop and no-op browser tab policy`() {
        // Mutant: default `ROW20_WEB_BLOCK_FALLBACK` or `ROW20_WEB_BLOCK_TAB_CLOSE` to `true` in `build.gradle.kts` ->
        // alters #1234 runtime behaviour when the contingency switch was not requested.
        val defaults = WebFilterRow20Fallback.currentConfig()
        assertFalse(defaults.extendedHopEnabled)
        assertFalse(defaults.tabCloseEnabled)
        assertEquals(WebFilterConnectionReset.DEFAULT_PAUSE_MS, WebFilterRow20Fallback.effectiveHopPauseMs(defaults))

        val policy = BrowserTabBlockPolicy()
        val decision = policy.evaluate(
            enabled = WebFilterRow20Fallback.isTabCloseEnabled(defaults),
            paired = true,
            consentPaused = false,
            lockActive = false,
            pausedInternet = false,
            browserPackage = "com.android.chrome",
            observation = BrowserTabBlockPolicy.UrlBarObservation("https://bad.example/video"),
            dnsConfig = DnsFilterPolicy.Config(blockedDomains = listOf("bad.example")),
            nowElapsedMs = 1_000L,
        )
        assertEquals(BrowserTabBlockPolicy.Decision.NONE, decision)
    }

    @Test
    fun `enabling extended hop lengthens TransientTunnelController sinkhole window and clamps bounds`() = runBlocking {
        // Mutant: ignore `pauseMsProvider` in `TransientTunnelController` -> hop stays 1_000L when fallback is enabled.
        assertEquals(
            1_000L,
            WebFilterRow20Fallback.effectiveHopPauseMs(
                WebFilterRow20Fallback.Config(extendedHopEnabled = true, extendedHopPauseMs = 250L, tabCloseEnabled = false),
            ),
        )
        assertEquals(
            15_000L,
            WebFilterRow20Fallback.effectiveHopPauseMs(
                WebFilterRow20Fallback.Config(extendedHopEnabled = true, extendedHopPauseMs = 60_000L, tabCloseEnabled = false),
            ),
        )

        WebFilterRow20Fallback.setOverrideForTest(
            WebFilterRow20Fallback.Config(extendedHopEnabled = true, extendedHopPauseMs = 5_000L, tabCloseEnabled = false),
        )
        val observedWaits = mutableListOf<Long>()
        var activeMode: String? = FilterVpnService.MODE_DNS
        val controller = WebFilterConnectionReset.TransientTunnelController(
            serviceInstanceId = { 7L },
            serviceDispatcher = WebFilterConnectionReset.ServiceDispatcher { it() },
            activeModeOnServiceThread = { activeMode },
            openModeOnServiceThread = { wanted, _ ->
                activeMode = wanted
                true
            },
            closeTunnelOnServiceThread = { activeMode = null },
            isInternetPausedOnServiceThread = { false },
            isConsentPausedOnServiceThread = { false },
            isLockActiveOnServiceThread = { false },
            waitMs = { ms -> observedWaits += ms },
            pauseMsProvider = { WebFilterRow20Fallback.effectiveHopPauseMs() },
        )

        val outcome = controller.executeReset(requestInstanceId = 7L)
        assertEquals(WebFilterConnectionReset.TransitionOutcome.COMPLETED, outcome)
        assertEquals(listOf(5_000L), observedWaits)
        assertEquals(FilterVpnService.MODE_DNS, activeMode)
    }

    @Test
    fun `extractNormalizedHost keeps only normalized DNS host and rejects search text, non-http schemes, and IP literals`() {
        // Mutant: fail to strip path/query/userinfo/port or accept whitespace -> privacy leak or search-phrase false block.
        assertEquals(
            "m.youtube.com",
            BrowserTabBlockPolicy.extractNormalizedHost("\u200Ehttps://user:pass@M.YouTube.com:443/watch?v=abc123#t=10\u200F"),
        )
        assertEquals(
            "bad.example.co.uk",
            BrowserTabBlockPolicy.extractNormalizedHost("http://bad.example.co.uk./deep/path?token=secret"),
        )
        assertEquals(
            "sub.blocked.org",
            BrowserTabBlockPolicy.extractNormalizedHost("sub.blocked.org/"),
        )

        assertNull(BrowserTabBlockPolicy.extractNormalizedHost(null))
        assertNull(BrowserTabBlockPolicy.extractNormalizedHost("   "))
        assertNull(BrowserTabBlockPolicy.extractNormalizedHost("Search or type web address"))
        assertNull(BrowserTabBlockPolicy.extractNormalizedHost("youtube funny cats"))
        assertNull(BrowserTabBlockPolicy.extractNormalizedHost("chrome://settings/privacy"))
        assertNull(BrowserTabBlockPolicy.extractNormalizedHost("about:blank"))
        assertNull(BrowserTabBlockPolicy.extractNormalizedHost("file:///sdcard/Download/index.html"))
        assertNull(BrowserTabBlockPolicy.extractNormalizedHost("http://192.0.2.10:8080/page"))
        assertNull(BrowserTabBlockPolicy.extractNormalizedHost("https://[::1]/page"))
        assertNull(BrowserTabBlockPolicy.extractNormalizedHost("localhost"))
    }

    @Test
    fun `BrowserTabBlockPolicy evicts only SINK hosts, ignores focused typing and rewrites, and bounds retries`() {
        // Mutant A: ignore `isFocusedEditable` -> typing in the address bar bounces mid-keystroke.
        // Mutant B: treat `DnsFilterPolicy.Action.REWRITE` as blocked -> SafeSearch / YouTube Restricted closes allowed tabs.
        // Mutant C: omit episode cap or debounce -> endless BACK/HOME loop on a stuck window.
        val policy = BrowserTabBlockPolicy(debounceMs = 750L, maxBackSteps = 2, episodeResetMs = 10_000L)
        val config = DnsFilterPolicy.Config(
            safeSearch = true,
            youtubeMode = "strict",
            allowedDomains = listOf("allowed.bad.example"),
            blockedDomains = listOf("bad.example"),
            categoryDomains = mapOf("adult.example" to "adult"),
            blockedCategories = listOf("adult"),
        )

        fun check(
            url: String?,
            nowMs: Long,
            focusedEditable: Boolean = false,
            consentPaused: Boolean = false,
            lockActive: Boolean = false,
            pausedInternet: Boolean = false,
            pkg: String = "com.android.chrome",
        ) = policy.evaluate(
            enabled = true,
            paired = true,
            consentPaused = consentPaused,
            lockActive = lockActive,
            pausedInternet = pausedInternet,
            browserPackage = pkg,
            observation = BrowserTabBlockPolicy.UrlBarObservation(url, isFocusedEditable = focusedEditable),
            dnsConfig = config,
            nowElapsedMs = nowMs,
        )

        // Guards: typing in omnibox, non-browser package, consent pause, lock, pause-internet, allowlist, and SafeSearch/YT rewrites.
        assertEquals(BrowserTabBlockPolicy.Decision.NONE, check("bad.example", 1_000L, focusedEditable = true))
        assertEquals(BrowserTabBlockPolicy.Decision.NONE, check("bad.example", 1_000L, pkg = "com.whatsapp"))
        assertEquals(BrowserTabBlockPolicy.Decision.NONE, check("bad.example", 1_000L, consentPaused = true))
        assertEquals(BrowserTabBlockPolicy.Decision.NONE, check("bad.example", 1_000L, lockActive = true))
        assertEquals(BrowserTabBlockPolicy.Decision.NONE, check("bad.example", 1_000L, pausedInternet = true))
        assertEquals(BrowserTabBlockPolicy.Decision.NONE, check("https://allowed.bad.example/page", 1_000L))
        assertEquals(BrowserTabBlockPolicy.Decision.NONE, check("https://www.google.com/search?q=math", 1_000L))
        assertEquals(BrowserTabBlockPolicy.Decision.NONE, check("https://m.youtube.com/watch?v=123", 1_000L))

        // Blocked domain (`bad.example`) -> 2x CLOSE_OR_BACK (debounced at 750 ms), 1x GO_HOME, then capped at NONE.
        assertEquals(
            BrowserTabBlockPolicy.Decision(BrowserTabBlockPolicy.Step.CLOSE_OR_BACK, pauseBrowserMedia = true),
            check("https://sub.bad.example/article", 10_000L),
        )
        assertEquals(BrowserTabBlockPolicy.Decision.NONE, check("https://sub.bad.example/article", 10_400L))
        assertEquals(
            BrowserTabBlockPolicy.Decision(BrowserTabBlockPolicy.Step.CLOSE_OR_BACK, pauseBrowserMedia = true),
            check("https://sub.bad.example/article", 10_800L),
        )
        assertEquals(
            BrowserTabBlockPolicy.Decision(BrowserTabBlockPolicy.Step.GO_HOME, pauseBrowserMedia = true),
            check("https://sub.bad.example/article", 11_600L),
        )
        assertEquals(BrowserTabBlockPolicy.Decision.NONE, check("https://sub.bad.example/article", 12_500L))

        // Navigating to an allowed page clears the episode so a fresh visit to a blocked category host acts immediately.
        assertEquals(BrowserTabBlockPolicy.Decision.NONE, check("https://en.wikipedia.org/wiki/Main_Page", 13_000L))
        assertEquals(
            BrowserTabBlockPolicy.Decision(BrowserTabBlockPolicy.Step.CLOSE_OR_BACK, pauseBrowserMedia = true),
            check("https://clips.adult.example/watch", 13_100L),
        )
    }

    @Test
    fun `production services wire both fallback paths behind WebFilterRow20Fallback and never log observed URLs`() {
        // Mutant: remove `WebFilterRow20Fallback` gates or log `observation`/`rawText` in `AccessibilityMonitorService`.
        val vpn = sourceFile("app/src/main/java/com/familyshield/agent/vpn/FilterVpnService.kt")
        val a11y = sourceFile("app/src/main/java/com/familyshield/agent/services/AccessibilityMonitorService.kt")

        assertTrue(vpn.contains("pauseMsProvider = { WebFilterRow20Fallback.effectiveHopPauseMs() }"))
        assertTrue(a11y.contains("if (com.familyshield.agent.vpn.WebFilterRow20Fallback.isTabCloseEnabled())"))

        val helper = a11y.substringAfter("private fun enforceBlockedBrowserTabIfEnabled(")
            .substringBefore("private fun refreshFilterRecovery()")
        assertTrue(helper.contains("media.onRaise(browserPkg)"))
        assertTrue(helper.contains("performGlobalAction(GLOBAL_ACTION_BACK)"))
        assertTrue(helper.contains("performGlobalAction(GLOBAL_ACTION_HOME)"))
        assertTrue(helper.contains("matches.forEach { runCatching { it.recycle() } }"))
        assertFalse("URL-bar reader must never log observed URLs or hosts", helper.contains("Log."))
    }

    private fun sourceFile(relative: String): String {
        var dir: File? = File(System.getProperty("user.dir") ?: ".").absoluteFile
        while (dir != null) {
            val candidate = File(dir, relative)
            if (candidate.isFile) return candidate.readText()
            dir = dir.parentFile
        }
        error("Could not find $relative")
    }
}
