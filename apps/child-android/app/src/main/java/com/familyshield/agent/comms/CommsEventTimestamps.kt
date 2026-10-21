package com.familyshield.agent.comms

import java.time.Instant

/**
 * Issue #260: the wire format for a comms event's own time.
 *
 * The server accepts `ts` on `POST /v1/devices/<id>/activity` and falls back to `new Date()` when it is
 * absent, so a batch used to be dated to the moment of the flush rather than to the calls and texts it
 * carried. Pure on purpose: the format is the contract with `z.string().datetime()` on the server, and
 * a JVM test pins it rather than leaving it to a phone row to notice.
 */
object CommsEventTimestamps {

    /** The event time as ISO-8601 UTC with milliseconds, e.g. `2026-10-21T06:06:52.123Z`. */
    fun isoUtc(epochMillis: Long): String = Instant.ofEpochMilli(epochMillis).toString()
}
