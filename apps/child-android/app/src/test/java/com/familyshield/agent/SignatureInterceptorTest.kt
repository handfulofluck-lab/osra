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
    fun `different secrets produce different signatures`() {
        val body = "{}".toByteArray()
        assertNotEquals(
            SignatureInterceptor.hmacSha256Hex("secret-a", body),
            SignatureInterceptor.hmacSha256Hex("secret-b", body),
        )
    }
}
