package com.familyshield.agent.content

import java.io.File
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** Pure-JVM + flavor-boundary tests for Full-only search capture (#939, ADR-0039 PR D). */
class SearchQueryParserTest {

    @Test
    fun `parses chrome google search URLs with and without scheme`() {
        val withScheme = SearchQueryParser.parseSearchUrl("https://www.google.ae/search?q=adult+content+test&oq=adult")
        assertNotNull(withScheme)
        assertEquals("google", withScheme?.engine)
        assertEquals("adult content test", withScheme?.query)

        val bare = SearchQueryParser.parseSearchUrl("www.google.com/search?q=what+to+search%3F")
        assertNotNull(bare)
        assertEquals("google", bare?.engine)
        assertEquals("what to search?", bare?.query)
    }

    @Test
    fun `parses youtube, bing, and duckduckgo search URLs and ignores non-search URLs`() {
        val yt = SearchQueryParser.parseSearchUrl("https://m.youtube.com/results?search_query=science+experiments")
        assertEquals("youtube", yt?.engine)
        assertEquals("science experiments", yt?.query)

        val bing = SearchQueryParser.parseSearchUrl("https://www.bing.com/search?q=weather+dubai")
        assertEquals("bing", bing?.engine)
        assertEquals("weather dubai", bing?.query)

        val ddg = SearchQueryParser.parseSearchUrl("https://duckduckgo.com/?q=privacy+tools")
        assertEquals("duckduckgo", ddg?.engine)
        assertEquals("privacy tools", ddg?.query)

        assertNull(SearchQueryParser.parseSearchUrl("https://example.com/article?id=123"))
        assertNull(SearchQueryParser.parseSearchUrl("https://www.youtube.com/watch?v=dQw4w9WgXcQ"))
    }

    @Test
    fun `extracts submitted search from chrome URL bar, SERP title or unfocused search field, never focused typing`() {
        val urlNodes = listOf(
            SearchNodeSnapshot("www.google.com/search?q=adult+content+check", viewIdResourceName = "com.android.chrome:id/url_bar"),
            SearchNodeSnapshot("Results", className = "android.widget.TextView"),
        )
        val urlParsed = SearchQueryParser.extractFromNodes("com.android.chrome", urlNodes)
        assertEquals("google", urlParsed?.engine)
        assertEquals("adult content check", urlParsed?.query)

        val nodes = listOf(
            SearchNodeSnapshot("google.com", viewIdResourceName = "com.android.chrome:id/url_bar"),
            SearchNodeSnapshot("adult video query - Google Search", className = "android.webkit.WebView"),
            SearchNodeSnapshot("result 1", className = "android.widget.TextView"),
            SearchNodeSnapshot("result 2", className = "android.widget.TextView"),
        )
        val parsed = SearchQueryParser.extractFromNodes("com.android.chrome", nodes)
        assertEquals("google", parsed?.engine)
        assertEquals("adult video query", parsed?.query)

        // Focused EditText while child is mid-typing must NOT emit partial queries.
        val typingNodes = listOf(
            SearchNodeSnapshot("com.android.chrome"),
            SearchNodeSnapshot("youtube.com", viewIdResourceName = "com.android.chrome:id/url_bar"),
            SearchNodeSnapshot("po", viewIdResourceName = "search_src_text", isEditable = true, isFocused = true),
            SearchNodeSnapshot("Trending", className = "android.widget.TextView"),
            SearchNodeSnapshot("Shorts", className = "android.widget.TextView"),
        )
        assertNull(SearchQueryParser.extractFromNodes("com.android.chrome", typingNodes))
    }

    @Test
    fun `unfocused youtube search field beside results captures query, skipping placeholders`() {
        val placeholderOnly = listOf(
            SearchNodeSnapshot("Search YouTube", viewIdResourceName = "com.google.android.youtube:id/search_src_text", isEditable = true),
            SearchNodeSnapshot("Home"),
            SearchNodeSnapshot("Shorts"),
            SearchNodeSnapshot("Subscriptions"),
        )
        assertNull(SearchQueryParser.extractFromNodes("com.google.android.youtube", placeholderOnly))

        val results = listOf(
            SearchNodeSnapshot("minecraft tutorial", viewIdResourceName = "com.google.android.youtube:id/search_src_text", isEditable = true, isFocused = false),
            SearchNodeSnapshot("Minecraft survival guide"),
            SearchNodeSnapshot("10:21"),
            SearchNodeSnapshot("1.2M views"),
        )
        val parsed = SearchQueryParser.extractFromNodes("com.google.android.youtube", results)
        assertEquals("youtube", parsed?.engine)
        assertEquals("minecraft tutorial", parsed?.query)
    }

    @Test
    fun `dedupe quiet window suppresses duplicate search within 5 minutes`() {
        val keyA = SearchQueryParser.dedupeKey(ParsedSearch("google", "Test Query"))
        val keyB = SearchQueryParser.dedupeKey(ParsedSearch("google", "test query"))
        assertEquals(keyA, keyB)
        assertTrue(SearchQueryParser.shouldSend(null, 100_000L))
        assertFalse(SearchQueryParser.shouldSend(100_000L, 100_000L + 60_000L))
        assertTrue(SearchQueryParser.shouldSend(100_000L, 100_000L + SearchQueryParser.DEDUPE_WINDOW_MS))
    }

    @Test
    fun `flavor split and AccessibilitySearchCapture consent and rule gates stay intact`() {
        val playImpl = source("apps/child-android/app/src/play/java/com/familyshield/agent/content/NoopSearchCapture.kt")
        assertTrue("Play build must bind NoopSearchCapture", playImpl.contains("= Unit"))
        assertFalse("Play build must never call postSearchEvent", playImpl.contains("postSearchEvent"))
        assertFalse("Play build must never enqueue search events", playImpl.contains("enqueueSearch"))

        val fullImpl = source("apps/child-android/app/src/full/java/com/familyshield/agent/content/AccessibilitySearchCapture.kt")
        val pauseIdx = fullImpl.indexOf("if (consent != null && consent.isPaused()) return")
        val ruleIdx = fullImpl.indexOf("if (rules != null && !rules.searchMonitoringEnabled()) return")
        val ownerIdx = fullImpl.indexOf("WindowOwnershipPolicy.selectVerifiedRoot(")
        val collectIdx = fullImpl.indexOf("collectNodes(")
        assertTrue("Full search capture checks consent pause before collecting nodes", pauseIdx in 0 until collectIdx)
        assertTrue("Full search capture checks rule flag before collecting nodes", ruleIdx in 0 until collectIdx)
        assertTrue("Full search capture verifies window ownership before collecting nodes", ownerIdx in 0 until collectIdx)
        assertTrue("Full search capture enqueues through the durable SocialScanQueue", fullImpl.contains("queue.enqueueSearch("))

        val queueImpl = source("apps/child-android/app/src/main/java/com/familyshield/agent/social/SocialScanQueue.kt")
        assertTrue("Durable scan queue uploads queued search rows to postSearchEvent", queueImpl.contains("api.postSearchEvent("))
    }

    private fun source(relative: String): String {
        var dir: File? = File(System.getProperty("user.dir") ?: ".").absoluteFile
        while (dir != null) {
            val candidate = File(dir, relative)
            if (candidate.isFile) return candidate.readText()
            dir = dir.parentFile
        }
        throw AssertionError("not found: $relative")
    }
}
