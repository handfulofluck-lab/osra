package com.familyshield.agent.comms

import com.familyshield.agent.data.db.CommsEventEntity
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Feature #6 / roadmap 4.5 — what a buffered row puts on the wire.
 *
 * The one thing that must not be got wrong: **a length that was never measured is absent**, not `0`. The parent
 * app reads a present `0` as a call that connected and ended instantly, which is why #526 had to hide it for
 * missed calls; a WhatsApp ring that was never answered has no length at all, so the key is not sent.
 */
class CommsCallPayloadTest {

    private fun call(
        number: String = "+15551234567",
        direction: String = "incoming",
        durationSec: Int? = 95,
        source: String? = null,
        durationApprox: Boolean = false,
    ) = CommsEventEntity(
        type = "call",
        number = number,
        direction = direction,
        durationSec = durationSec,
        timestamp = 1_792_564_893_890L,
        source = source,
        durationApprox = durationApprox,
    )

    @Test
    fun `a carrier call is unchanged, including the zero a missed call carries`() {
        val payload = CommsPayloadPolicy.payloadFor(call(durationSec = 0, direction = "missed"))
        assertEquals(0, payload["durationSec"])
        assertFalse("a carrier call is not sourced", payload.containsKey("source"))
        assertFalse("and it is not approximate", payload.containsKey("durationApprox"))
        assertEquals("missed", payload["direction"])
    }

    @Test
    fun `a WhatsApp call that was never answered sends no duration at all`() {
        val payload = CommsPayloadPolicy.payloadFor(
            call(direction = WhatsAppCallDirection.UNKNOWN, durationSec = null, source = "whatsapp"),
        )
        assertFalse("absent, never 0", payload.containsKey("durationSec"))
        assertEquals("whatsapp", payload["source"])
        assertEquals("unknown", payload["direction"])
    }

    @Test
    fun `an answered WhatsApp call says the length is approximate`() {
        val payload = CommsPayloadPolicy.payloadFor(
            call(durationSec = 35, source = "whatsapp", durationApprox = true),
        )
        assertEquals(35, payload["durationSec"])
        assertEquals(true, payload["durationApprox"])
        assertEquals("whatsapp", payload["source"])
    }

    @Test
    fun `an SMS row keeps the body preview and gains nothing`() {
        val sms = CommsEventEntity(
            type = "sms",
            number = "+15551234567",
            direction = "incoming",
            bodyPreview = "see you at six",
            timestamp = 1_792_564_893_890L,
        )
        val payload = CommsPayloadPolicy.payloadFor(sms)
        assertEquals("see you at six", payload["bodyPreview"])
        assertFalse("no call fields on a text", payload.containsKey("direction"))
        assertTrue(payload.containsKey("number"))
    }

    /** The wire value, named here so a typo in a test is a compile error rather than a passing row. */
    private object WhatsAppCallDirection {
        const val UNKNOWN = "unknown"
    }
}
