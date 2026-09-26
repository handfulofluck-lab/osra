package com.familyshield.agent

import com.familyshield.agent.network.ServerUrls
import org.junit.Assert.assertEquals
import org.junit.Test

/** Pure-JVM tests for tester-entered server URL normalization (§14.2). */
class ServerUrlsTest {

    @Test
    fun `bare host and port gets an http scheme`() {
        assertEquals("http://192.168.1.5:3000", ServerUrls.normalize("192.168.1.5:3000"))
    }

    @Test
    fun `existing scheme is preserved`() {
        assertEquals("https://example.com", ServerUrls.normalize("https://example.com"))
        assertEquals("http://example.com", ServerUrls.normalize("http://example.com"))
    }

    @Test
    fun `trailing slashes are stripped so paths can be appended`() {
        assertEquals("http://a.com/api", ServerUrls.normalize("http://a.com/api///"))
        assertEquals("http://a.com", ServerUrls.normalize("http://a.com/"))
    }

    @Test
    fun `whitespace is trimmed`() {
        assertEquals("http://a.com", ServerUrls.normalize("  http://a.com  "))
    }

    @Test
    fun `blank stays blank`() {
        assertEquals("", ServerUrls.normalize(""))
        assertEquals("", ServerUrls.normalize("   "))
    }

    @Test
    fun `host with a path prefix but no scheme is handled`() {
        assertEquals("http://example.com/api", ServerUrls.normalize("example.com/api"))
    }
}
