package com.familyshield.agent.social

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Roadmap 4.5, the parser half: a WhatsApp call becomes a call row — who, when, roughly how long, never
 * content. Claude's faults for this item are the row list below, and the three that this object cannot own
 * are named at the bottom so nobody reads a green suite as covering them.
 */
class WhatsAppCallPolicyTest {

    private val start = 1_792_563_200_000L

    private fun call(
        key: String = "whatsapp-call-1",
        title: String? = "Mama",
        text: String? = null,
        ongoing: Boolean = true,
        missed: Boolean = false,
        at: Long = start,
        pkg: String = "com.whatsapp",
    ) = WhatsAppCallPolicy.Snapshot(pkg, key, title, text, ongoing, missed, at)

    @Test
    fun `a ringing call is an incoming call with no duration yet`() {
        val row = WhatsAppCallPolicy.started(call())
        assertEquals("Mama", row!!.contact)
        assertEquals("incoming", row.direction)
        assertNull("we have not timed it yet", row.durationSec)
        assertFalse("and we must not claim a measurement", row.durationApprox)
    }

    @Test
    fun `an ended call carries an approximate duration`() {
        val row = WhatsAppCallPolicy.ended(call(ongoing = false, at = start + 92_000L), start)!!
        assertEquals("Mama", row.contact)
        assertEquals(92L, row.durationSec)
        assertTrue("notification timing, not a stopwatch", row.durationApprox)
        assertEquals("the start is the heads-up, not the removal", start, row.startMs)
    }

    @Test
    fun `a missed call carries no duration at all`() {
        // Claude's fault 2: a missed call with a duration. Null, not 0 - "0 s" reads as a call that
        // connected and ended instantly rather than one the child never answered.
        val row = WhatsAppCallPolicy.missed(call(missed = true, ongoing = false, at = start + 30_000L))!!
        assertEquals("missed", row.direction)
        assertNull(row.durationSec)
        assertFalse(row.durationApprox)
    }

    @Test
    fun `the notification text never reaches the row`() {
        // Claude's fault 4: the body copied into the payload. The row has no field that could hold it, and
        // this pins the values anyway: only the caller name survives.
        val withBody = call(text = "hey, are you there? call me back")
        val started = WhatsAppCallPolicy.started(withBody)!!
        val ended = WhatsAppCallPolicy.ended(withBody.copy(isOngoing = false, postedAtMs = start + 5_000L), start)!!
        listOf(started, ended).forEach { row ->
            assertFalse(
                "no field of the row may carry the notification body",
                listOf(row.contact, row.direction, row.key).any { it.contains("call me back") },
            )
            assertEquals("Mama", row.contact)
        }
    }

    @Test
    fun `a re-posted heads-up is one row`() {
        // Claude's fault 5: the ongoing notification re-posted (ring, in progress, ended) making four rows.
        // The identity is key + start, so every re-post of the same call hashes to the same value.
        val ring = WhatsAppCallPolicy.started(call(at = start))!!
        val inProgress = WhatsAppCallPolicy.started(call(at = start + 3_000L))!!.copy(startMs = start)
        val ended = WhatsAppCallPolicy.ended(call(ongoing = false, at = start + 40_000L), start)!!
        assertEquals(WhatsAppCallPolicy.identity(ring), WhatsAppCallPolicy.identity(inProgress))
        assertEquals(WhatsAppCallPolicy.identity(ring), WhatsAppCallPolicy.identity(ended))
        assertTrue(
            "and two calls from the same person in the same second stay two",
            WhatsAppCallPolicy.identity(ended) != WhatsAppCallPolicy.identity(ended.copy(key = "whatsapp-call-2")),
        )
    }

    @Test
    fun `another app, an unnamed call and a negative gap are all refused or bounded`() {
        // Not WhatsApp: Telegram and the phone's own dialer never reach this parser.
        assertNull(WhatsAppCallPolicy.started(call(pkg = "org.telegram.messenger")))
        assertNull(WhatsAppCallPolicy.started(call(pkg = "com.android.dialer")))
        // No name means no row the parent can act on.
        assertNull(WhatsAppCallPolicy.started(call(title = "   ")))
        // A clock that went backwards cannot produce a negative duration, and a wild one is bounded.
        assertEquals(0L, WhatsAppCallPolicy.ended(call(ongoing = false, at = start - 5_000L), start)!!.durationSec)
        assertEquals(
            24L * 60 * 60,
            WhatsAppCallPolicy.ended(call(ongoing = false, at = start + 48L * 60 * 60 * 1000), start)!!.durationSec,
        )
    }

    @Test
    fun `WhatsApp Business is the same app key`() {
        // `com.whatsapp.w4b` maps to the same key in MonitoredApps; a business profile is still the child's call.
        val row = WhatsAppCallPolicy.started(call(pkg = "com.whatsapp.w4b"))
        assertEquals("Mama", row!!.contact)
    }

    // What this suite cannot own, stated so a green run is not read as more than it is:
    //  - fault 1, "a call that started during a pause gets uploaded": the pause gate lives in CommLogger /
    //    the capture service, and the row belongs there, not in a pure parser.
    //  - fault 6, "the Play flavour captures WhatsApp calls": a build-flavour question, checked by the
    //    manifest/flavour tests and assembleDebug.
    //  - fault 7, "a row without `source` is shown as WhatsApp": server payload plus parent-app rendering.
}
