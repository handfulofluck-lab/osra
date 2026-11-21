package com.familyshield.agent

import com.familyshield.agent.network.SignatureInterceptor
import java.util.concurrent.TimeUnit
import okhttp3.Call
import okhttp3.Connection
import okhttp3.Interceptor
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.Protocol
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
import okhttp3.Response
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** Pure-JVM tests for the HMAC-SHA256 request signing helper (§12.3). */
class SignatureInterceptorTest {

    @Test
    fun `hmac matches the well-known test vector`() {
        // Reference vector: HMAC-SHA256(key="key") over the classic pangram.
        val hex = SignatureInterceptor.hmacSha256Hex(
            "key",
            "The quick brown fox jumps over the lazy dog".toByteArray(),
        )
        assertEquals(
            "f7bc83f430538424b13298e6aa6fb143ef4d59a14946175997479dbc2d1a3cd8",
            hex,
        )
    }

    @Test
    fun `signature is 64 lowercase hex chars even for an empty body`() {
        val hex = SignatureInterceptor.hmacSha256Hex("secret", ByteArray(0))
        assertEquals(64, hex.length)
        assertTrue(hex.matches(Regex("[0-9a-f]+")))
    }

    @Test
    fun `v2 signing string is timestamp dot nonce dot body, byte for byte`() {
        val bytes = SignatureInterceptor.signingBytes("1800000000", "0123456789abcdef0123456789abcdef", "{\"a\":1}".toByteArray())
        assertEquals("1800000000.0123456789abcdef0123456789abcdef.{\"a\":1}", String(bytes))
    }

    @Test
    fun `v2 signature matches the server's reference (HMAC over the signing string)`() {
        // Server reference: signV2("device-secret-1", body, {timestamp: 1800000000, nonce: "nonce-0123456789abcdef"})
        val body = "{\"childId\":\"child-1\",\"deviceId\":\"dev-1\",\"title\":\"x\"}".toByteArray()
        val hex = SignatureInterceptor.hmacSha256Hex(
            "device-secret-1",
            SignatureInterceptor.signingBytes("1800000000", "nonce-0123456789abcdef", body),
        )
        assertEquals("ce725cf93f36fb43a586bcae590b3faab54afa4976347b859c9ca9259c220508", hex)
    }

    @Test
    fun `nonces are 32 lowercase hex chars and unique`() {
        val a = SignatureInterceptor.newNonce()
        val b = SignatureInterceptor.newNonce()
        assertEquals(32, a.length)
        assertTrue(a.matches(Regex("[0-9a-f]+")))
        assertNotEquals(a, b)
    }

    @Test
    fun `different secrets produce different signatures`() {
        val body = "{}".toByteArray()
        assertNotEquals(
            SignatureInterceptor.hmacSha256Hex("secret-a", body),
            SignatureInterceptor.hmacSha256Hex("secret-b", body),
        )
    }

    @Test
    fun `intercept signs alerts internal, social scan, and content search routes with v2 headers`() {
        val bodyJson = "{\"items\":[]}"
        val interceptor = SignatureInterceptor { "device-secret-1" }.apply {
            clock = { 1800000000L }
            nonceProvider = { "nonce-0123456789abcdef" }
        }
        for (path in listOf("v1/alerts/internal", "v1/social/scan", "v1/content/search-event", "v1/content/youtube-watch")) {
            val captured = runIntercept(interceptor, "https://api.staging.osratech.com/$path", bodyJson)
            assertEquals("1800000000", captured.header(SignatureInterceptor.HEADER_TIMESTAMP))
            assertEquals("nonce-0123456789abcdef", captured.header(SignatureInterceptor.HEADER_NONCE))
            val expectedSig = SignatureInterceptor.hmacSha256Hex(
                "device-secret-1",
                SignatureInterceptor.signingBytes("1800000000", "nonce-0123456789abcdef", bodyJson.toByteArray()),
            )
            assertEquals("must sign $path", expectedSig, captured.header(SignatureInterceptor.HEADER))
        }
    }

    @Test
    fun `intercept leaves non-internal device telemetry and rules unsigned`() {
        val interceptor = SignatureInterceptor { "device-secret-1" }
        for (path in listOf("v1/devices/dev-1/telemetry", "v1/devices/dev-1/activity", "v1/rules/child-1")) {
            val captured = runIntercept(interceptor, "https://api.staging.osratech.com/$path", "{}")
            assertNull("must not add HMAC header to $path", captured.header(SignatureInterceptor.HEADER))
            assertNull(captured.header(SignatureInterceptor.HEADER_TIMESTAMP))
            assertNull(captured.header(SignatureInterceptor.HEADER_NONCE))
        }
        assertFalse(SignatureInterceptor.shouldSign(listOf("v1", "devices", "dev-1", "telemetry")))
        assertNotNull(SignatureInterceptor.shouldSign(listOf("v1", "social", "scan")))
    }

    private fun runIntercept(interceptor: SignatureInterceptor, url: String, json: String): Request {
        var seen: Request? = null
        val req = Request.Builder()
            .url(url)
            .post(json.toRequestBody("application/json".toMediaType()))
            .build()
        interceptor.intercept(object : Interceptor.Chain {
            override fun request(): Request = req
            override fun proceed(request: Request): Response {
                seen = request
                return Response.Builder()
                    .request(request)
                    .protocol(Protocol.HTTP_1_1)
                    .code(200)
                    .message("OK")
                    .build()
            }
            override fun connection(): Connection? = null
            override fun call(): Call = throw UnsupportedOperationException()
            override fun connectTimeoutMillis(): Int = 1000
            override fun withConnectTimeout(timeout: Int, unit: TimeUnit): Interceptor.Chain = this
            override fun readTimeoutMillis(): Int = 1000
            override fun withReadTimeout(timeout: Int, unit: TimeUnit): Interceptor.Chain = this
            override fun writeTimeoutMillis(): Int = 1000
            override fun withWriteTimeout(timeout: Int, unit: TimeUnit): Interceptor.Chain = this
        })
        return seen!!
    }
}
