package com.familyshield.agent

import com.familyshield.agent.social.SocialHeuristics
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** Pure-JVM tests for the social capture heuristics (contact/message extraction, debounce). */
class SocialHeuristicsTest {

    @Test
    fun `whatsapp chat sample picks title as contact and longest bubble as message`() {
        // WhatsApp-ish toolbar-then-bubbles node order.
        val texts = listOf(
            "Alex Rivera", // toolbar title = contact
            "typing…", // status node, short, precedes? real trees vary; message wins by length
            "hey",
            "are you coming to practice today or not?",
            "yes!",
            "ok see you at 6",
        )
        val (contact, message) = SocialHeuristics.extractContactAndMessage(texts)
        assertEquals("Alex Rivera", contact)
        assertEquals("are you coming to practice today or not?", message)
    }

    @Test
    fun `message is the longest text node even when first`() {
        val (contact, message) = SocialHeuristics.extractContactAndMessage(
            listOf("this is a very long message body that is clearly the chat text", "Mom"),
        )
        assertEquals("this is a very long message body that is clearly the chat text", message)
        assertEquals("Mom", contact)
    }

    @Test
    fun `contact is never the message body`() {
        val single = listOf("a long standalone message with no contact anywhere at all")
        val (contact, message) = SocialHeuristics.extractContactAndMessage(single)
        assertEquals(single[0], message)
        assertNull(contact) // the only node is the message; nothing else qualifies
    }

    @Test
    fun `empty input yields nulls`() {
        val (contact, message) = SocialHeuristics.extractContactAndMessage(emptyList())
        assertNull(contact)
        assertNull(message)
    }

    @Test
    fun `overlong nodes and multiline nodes are not contacts`() {
        val longTitle = "x".repeat(SocialHeuristics.MAX_CONTACT_LENGTH + 1)
        val multiline = "line1\nline2"
        val (contact, _) = SocialHeuristics.extractContactAndMessage(listOf(longTitle, multiline, "hi"))
        assertEquals("hi", contact)
    }

    @Test
    fun `debounce key is the app key`() {
        assertEquals("whatsapp", SocialHeuristics.debounceKey("whatsapp"))
        assertEquals("roblox", SocialHeuristics.debounceKey("roblox"))
    }

    @Test
    fun `shouldCapture allows first event and events past the window`() {
        val now = 10_000L
        assertTrue(SocialHeuristics.shouldCapture(null, now))
        assertFalse(SocialHeuristics.shouldCapture(now - 500L, now)) // within 1500 ms debounce
        assertTrue(SocialHeuristics.shouldCapture(now - 1500L, now)) // exactly at the window edge
        assertTrue(SocialHeuristics.shouldCapture(now - 5000L, now))
    }
}
