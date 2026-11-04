package com.familyshield.agent.network

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * ADR-0034 decision 4 (amendment A3): `X-OSRA-Client` is exactly the shape the server parses, or it is not
 * sent at all.
 *
 * The server's rule is the contract here (`services/api/src/lib/clientHeader.ts`): one pattern, 64 characters
 * maximum, every version part 1–4 digits, flavour `[a-z0-9-]{1,16}`, and **everything that does not match is
 * legacy** — served as an unversioned client, which is why a null from [ClientHeader.value] is a decision and
 * not a failure.
 */
class ClientHeaderTest {

    @Test
    fun `the shipped build names itself in the exact shape the server parses`() {
        assertEquals("child-android/0.2.0+2 (full)", ClientHeader.value("0.2.0", 2, ClientHeader.FLAVOUR_FULL))
        assertEquals("child-android/0.2.0+2 (play)", ClientHeader.value("0.2.0", 2, ClientHeader.FLAVOUR_PLAY))
        // The pattern the server tests against, kept here so a change to either side is a failure on this row.
        val serverPattern =
            Regex("^(parent-app|child-android|child-ios|agent-desktop|agent-macos)/\\d{1,4}\\.\\d{1,4}\\.\\d{1,4}\\+\\d{1,9} \\([a-z0-9-]{1,16}\\)$")
        assertTrue(serverPattern.matches(ClientHeader.value("0.2.0", 2, "full")!!))
    }

    @Test
    fun `a two-part version name is padded, because Gradle allows it and the wire does not`() {
        assertEquals("child-android/0.2.0+7 (full)", ClientHeader.value("0.2", 7, "full"))
        assertEquals("child-android/1.0.0+7 (play)", ClientHeader.value("1", 7, "play"))
    }

    @Test
    fun `a version the wire cannot express sends no header rather than a wrong one`() {
        // A wrong build number is worse than none: the version gate reads this number, and the server cannot
        // tell a typo from a release.
        assertNull("four parts", ClientHeader.value("0.2.0.1", 2, "full"))
        assertNull("a non-numeric part", ClientHeader.value("0.2.0-rc1", 2, "full"))
        assertNull("a part longer than four digits", ClientHeader.value("0.20000.0", 2, "full"))
        assertNull("no version name", ClientHeader.value(null, 2, "full"))
        assertNull("a version name of spaces", ClientHeader.value("   ", 2, "full"))
        assertNull("an empty part", ClientHeader.value("0..0", 2, "full"))
        assertNull("no build number", ClientHeader.value("0.2.0", 0, "full"))
    }

    @Test
    fun `a flavour outside the server's vocabulary sends no header`() {
        assertNull("upper case would not match", ClientHeader.value("0.2.0", 2, "Full"))
        assertNull("too long", ClientHeader.value("0.2.0", 2, "f".repeat(17)))
        assertNull("empty", ClientHeader.value("0.2.0", 2, ""))
        assertNull("a space", ClientHeader.value("0.2.0", 2, "full debug"))
        assertEquals("a hyphen is allowed by the server", "child-android/0.2.0+2 (test-only)", ClientHeader.value("0.2.0", 2, "test-only"))
    }

    @Test
    fun `the value never exceeds the server's cap`() {
        val value = ClientHeader.value("9999.9999.9999", 999_999_999, "abcdefghijklmnop")!!
        assertTrue("${value.length} characters", value.length <= ClientHeader.MAX_LENGTH)
    }
}
