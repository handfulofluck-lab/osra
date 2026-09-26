package com.familyshield.agent

import com.familyshield.agent.network.DynamicBaseUrlInterceptor
import okhttp3.HttpUrl.Companion.toHttpUrl
import org.junit.Assert.assertEquals
import org.junit.Test

/** Pure-JVM tests for the dynamic base-URL path rewriting (§14.2 port/path/https edge cases). */
class DynamicBaseUrlInterceptorTest {

    @Test
    fun `root base path leaves the request path untouched`() {
        val base = "http://192.168.1.5:3000".toHttpUrl()
        assertEquals("/", base.encodedPath)
        assertEquals(
            "/v1/rules/child-1",
            DynamicBaseUrlInterceptor.rewritePath(base.encodedPath, "/v1/rules/child-1"),
        )
    }

    @Test
    fun `base path prefix is prepended to the request path`() {
        val base = "http://host:3000/api/".toHttpUrl()
        assertEquals(
            "/api/v1/location/ping",
            DynamicBaseUrlInterceptor.rewritePath(base.encodedPath, "/v1/location/ping"),
        )
    }

    @Test
    fun `base path without trailing slash also works`() {
        val base = "http://host/api".toHttpUrl()
        assertEquals("/api/v1/x", DynamicBaseUrlInterceptor.rewritePath(base.encodedPath, "/v1/x"))
    }

    @Test
    fun `https scheme and custom port survive parsing (inputs to the interceptor)`() {
        val base = "https://example.com:8443/api".toHttpUrl()
        assertEquals("https", base.scheme)
        assertEquals("example.com", base.host)
        assertEquals(8443, base.port)
        assertEquals(
            "/api/v1/devices/d1/commands",
            DynamicBaseUrlInterceptor.rewritePath(base.encodedPath, "/v1/devices/d1/commands"),
        )
    }

    @Test
    fun `default ports are what the interceptor re-applies when the URL has none`() {
        assertEquals(443, "https://example.com".toHttpUrl().port)
        assertEquals(80, "http://example.com".toHttpUrl().port)
    }
}
