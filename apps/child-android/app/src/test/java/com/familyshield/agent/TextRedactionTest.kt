package com.familyshield.agent

import com.familyshield.agent.social.TextRedaction
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/** Pure-JVM tests for social text redaction (Feature #2/#17). */
class TextRedactionTest {

    @Test
    fun `email address is replaced`() {
        assertEquals(
            "reach me at [email] please",
            TextRedaction.redact("reach me at john.doe+1@example.com please"),
        )
    }

    @Test
    fun `phone number is replaced`() {
        assertEquals("call [phone] now", TextRedaction.redact("call +1 (202) 555-0123 now"))
        assertEquals("call [phone] now", TextRedaction.redact("call 202-555-0123 now"))
        assertEquals("call [phone] now", TextRedaction.redact("call +20 100 123 4567 now"))
    }

    @Test
    fun `digit run of four or more is replaced`() {
        assertEquals("my code is [num]", TextRedaction.redact("my code is 1234"))
        assertEquals("[num] was the year", TextRedaction.redact("2024 was the year"))
    }

    @Test
    fun `short digit runs are kept`() {
        assertEquals("only 3 digits: 123 ok", TextRedaction.redact("only 3 digits: 123 ok"))
    }

    @Test
    fun `multiple secrets in one string are all replaced`() {
        assertEquals(
            "[email] / [phone] / [num]",
            TextRedaction.redact("a@b.co / 555-123-4567 / 987654"),
        )
    }

    @Test
    fun `redaction is idempotent`() {
        val once = TextRedaction.redact("mail a@b.com, phone +1 202 555 0123, pin 4455")
        val twice = TextRedaction.redact(once)
        assertEquals(once, twice)
        assertFalse(once.contains("4455"))
        assertFalse(once.contains("a@b.com"))
        assertTrue(once.contains("[email]"))
        assertTrue(once.contains("[phone]"))
        assertTrue(once.contains("[num]"))
    }

    @Test
    fun `plain chat text is untouched`() {
        val chat = "hey, are you coming to the game tonight?"
        assertEquals(chat, TextRedaction.redact(chat))
    }
}
