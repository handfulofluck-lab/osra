package com.familyshield.agent.setup

import org.junit.Assert.assertEquals
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Mirrors `apps/parent-app/test/pair_qr_payload_test.dart`. The child and the parent must agree on
 * what a v1 payload is, so every case the Dart encoder refuses has a decoder case here that refuses
 * the same bytes for a stated reason.
 */
class PairQrPayloadTest {

    private val valid = "osra://pair?v=1&code=482916&host=http%3A%2F%2F192.168.1.5%3A3000"

    private fun reason(raw: String): String =
        assertThrows(PairQrFormatException::class.java) { PairQrPayload.decode(raw) }.message.orEmpty()

    @Test
    fun `decodes the documented v1 payload into code and API base`() {
        val payload = PairQrPayload.decode(valid)
        assertEquals("482916", payload.code)
        assertEquals("http://192.168.1.5:3000", payload.apiBaseUrl)
    }

    @Test
    fun `keeps an https host with a path and a leading-zero code`() {
        val payload = PairQrPayload.decode(
            "osra://pair?v=1&code=000042&host=https%3A%2F%2Fosra.example.com%2Fapi",
        )
        assertEquals("000042", payload.code)
        assertEquals("https://osra.example.com/api", payload.apiBaseUrl)
    }

    @Test
    fun `accepts an empty path and a single trailing slash`() {
        assertEquals("482916", PairQrPayload.decode(valid).code)
        assertEquals(
            "482916",
            PairQrPayload.decode("osra://pair/?v=1&code=482916&host=http%3A%2F%2F192.168.1.5%3A3000").code,
        )
    }

    @Test
    fun `refuses an unknown or missing version`() {
        assertTrue(
            reason("osra://pair?v=2&code=482916&host=http%3A%2F%2Fx"),
            reason("osra://pair?v=2&code=482916&host=http%3A%2F%2Fx").contains("unsupported pairing code version: 2"),
        )
        assertTrue(
            reason("osra://pair?code=482916&host=http%3A%2F%2Fx"),
            reason("osra://pair?code=482916&host=http%3A%2F%2Fx").contains("unsupported pairing code version: missing"),
        )
    }

    @Test
    fun `refuses a code that is not exactly six digits`() {
        for (raw in listOf(
            "osra://pair?v=1&code=12&host=http%3A%2F%2Fx",
            "osra://pair?v=1&code=1234567&host=http%3A%2F%2Fx",
            "osra://pair?v=1&code=ABC123&host=http%3A%2F%2Fx",
            "osra://pair?v=1&code=48291a&host=http%3A%2F%2Fx",
            "osra://pair?v=1&host=http%3A%2F%2Fx",
        )) {
            assertTrue(raw, reason(raw).contains("not six digits"))
        }
    }

    @Test
    fun `refuses a missing, non-http or malformed host`() {
        for (raw in listOf(
            "osra://pair?v=1&code=482916",
            "osra://pair?v=1&code=482916&host=192.168.1.5%3A3000",
            "osra://pair?v=1&code=482916&host=ftp%3A%2F%2Fexample.com",
            "osra://pair?v=1&code=482916&host=http%3A%2F%2F",
            "osra://pair?v=1&code=482916&host=http%3A%2F%2Fx%3Fa%3D1",
            "osra://pair?v=1&code=482916&host=http%3A%2F%2Fx%23frag",
        )) {
            assertTrue(raw, reason(raw).contains("not an http(s) URL"))
        }
    }

    @Test
    fun `refuses a bare code, another scheme or another authority, and a path`() {
        for (raw in listOf(
            "482916",
            "https://pair?v=1&code=482916&host=http%3A%2F%2Fx",
            "osra://join?v=1&code=482916&host=http%3A%2F%2Fx",
            "osra://pair/other?v=1&code=482916&host=http%3A%2F%2Fx",
        )) {
            assertEquals(raw, "not an OSRA pairing code", reason(raw))
        }
    }

    @Test
    fun `ignores extra query parameters like the Dart decoder`() {
        assertEquals(
            "482916",
            PairQrPayload.decode("osra://pair?v=1&code=482916&host=http%3A%2F%2Fx&extra=1").code,
        )
    }

    @Test
    fun `refuses malformed percent-encoding instead of guessing`() {
        val message = reason("osra://pair?v=1&code=482916&host=http%3A%2F%2Fx%ZZ")
        assertTrue(message, message == "not an OSRA pairing code" || message.contains("malformed percent-encoding"))
    }

    @Test
    fun `masks all but the last two digits`() {
        val payload = PairQrPayload.decode(valid)
        assertEquals("••••16", payload.maskedCode())
        assertTrue("the masked form leaks no other digit", payload.maskedCode().filter { it.isDigit() } == "16")
    }

    @Test
    fun `encodes the same string as the parent helper`() {
        assertEquals(
            valid,
            PairQrPayload(code = "482916", apiBaseUrl = "http://192.168.1.5:3000").encode(),
        )
        assertEquals(
            "osra://pair?v=1&code=000042&host=https%3A%2F%2Fosra.example.com%2Fapi",
            PairQrPayload(code = "000042", apiBaseUrl = "https://osra.example.com/api").encode(),
        )
    }

    @Test
    fun `encoding refuses a bad code or a non-http host`() {
        assertThrows(IllegalArgumentException::class.java) {
            PairQrPayload(code = "ABC123", apiBaseUrl = "http://192.168.1.5:3000").encode()
        }
        assertThrows(IllegalArgumentException::class.java) {
            PairQrPayload(code = "482916", apiBaseUrl = "192.168.1.5:3000").encode()
        }
    }

    @Test
    fun `round-trips every field`() {
        val original = PairQrPayload(code = "482916", apiBaseUrl = "http://10.0.2.2:3000")
        assertEquals(original, PairQrPayload.decode(original.encode()))
    }
}
