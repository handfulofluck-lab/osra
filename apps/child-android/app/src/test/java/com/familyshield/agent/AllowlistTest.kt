package com.familyshield.agent

import com.familyshield.agent.comms.Allowlist
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/** Pure-JVM tests for the Feature #27 contact allowlist (normalization + country-code tolerance). */
class AllowlistTest {

    @Test
    fun `normalize strips all non digits`() {
        assertEquals("12025550123", Allowlist.normalizeNumber("+1 (202) 555-0123"))
        assertEquals("201001234567", Allowlist.normalizeNumber("+20 100 123 4567"))
        assertEquals("", Allowlist.normalizeNumber("Alex Rivera"))
    }

    @Test
    fun `exact normalized match is allowed`() {
        assertTrue(Allowlist.isAllowed("202-555-0123", listOf("+1 (202) 555-0123")))
    }

    @Test
    fun `country code tolerance matches local against international`() {
        // NOTE: the US number without the +1 country code is a suffix of the stored entry.
        assertTrue(Allowlist.isAllowed("2025550123", listOf("+1 202-555-0123")))
        // And the stored local entry matches an incoming international number.
        assertTrue(Allowlist.isAllowed("+1 202 555 0123", listOf("2025550123")))
    }

    @Test
    fun `short suffixes below the minimum do not match`() {
        // "234" alone must not "match" a longer allowlisted number.
        assertFalse(Allowlist.isAllowed("234", listOf("5550123")))
    }

    @Test
    fun `unknown number with non-empty allowlist is an unknown contact`() {
        assertTrue(Allowlist.isUnknownContact("+1 303 555 7788", listOf("202-555-0123")))
    }

    @Test
    fun `allowlisted number is not unknown`() {
        assertFalse(Allowlist.isUnknownContact("202-555-0123", listOf("+1 (202) 555-0123")))
    }

    @Test
    fun `empty allowlist disables alerting entirely`() {
        assertFalse(Allowlist.isUnknownContact("+1 303 555 7788", emptyList()))
        assertFalse(Allowlist.isUnknownContact("999-888-7777", emptyList()))
    }

    @Test
    fun `names and short codes never alert`() {
        val allowlist = listOf("202-555-0123")
        assertFalse(Allowlist.isUnknownContact("Mom", allowlist))
        assertFalse(Allowlist.isUnknownContact("911", allowlist))
    }
}
