package com.familyshield.agent

import com.familyshield.agent.network.SignatureInterceptor
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotEquals
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
}
