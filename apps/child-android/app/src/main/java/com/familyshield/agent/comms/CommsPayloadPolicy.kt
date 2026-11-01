package com.familyshield.agent.comms

import com.familyshield.agent.data.db.CommsEventEntity

/**
 * Feature #6 / roadmap 4.5 — the wire payload for a buffered call or SMS row, as a pure function.
 *
 * It exists because one of these fields is now **absent sometimes**: a WhatsApp call that was never answered has
 * no length, and sending `0` there tells the parent the call connected and ended instantly (#526). The absence
 * is the kind of thing an adapter gets wrong silently, so the mapping is a JVM test and
 * [CommsLogger] is a one-line caller.
 */
object CommsPayloadPolicy {

    /** The `payload` object of the activity event for [event] — call and sms shapes differ on the server. */
    fun payloadFor(event: CommsEventEntity): Map<String, Any?> = when (event.type) {
        "call" -> buildMap {
            put("number", event.number)
            // Omitted, not zero: `0` is a real length on a carrier missed call and a lie on a WhatsApp ring.
            event.durationSec?.let { put("durationSec", it) }
            put("direction", event.direction)
            event.source?.let { put("source", it) }
            if (event.durationApprox) put("durationApprox", true)
        }
        else -> mapOf(
            "number" to event.number,
            "bodyPreview" to (event.bodyPreview ?: ""),
        )
    }
}
