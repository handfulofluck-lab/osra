package com.familyshield.agent

import com.familyshield.agent.telemetry.liveActivityPayload
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/** Pure-JVM tests for the Feature #29 live-activity app_usage payload builder. */
class LiveActivityTest {

    @Test
    fun `per-app snapshot is aggregated into the total minutes`() {
        val event = liveActivityPayload(mapOf("com.a" to 3, "com.b" to 7, "com.c" to 0), "com.a")
        assertEquals("app_usage", event.type)
        assertEquals("com.a", event.payload["app"])
        assertEquals(10, event.payload["minutes"])
    }

    @Test
    fun `missing foreground falls back to idle`() {
        val event = liveActivityPayload(mapOf("com.a" to 4), null)
        assertEquals("app_usage", event.type)
        assertEquals("idle", event.payload["app"])
        assertEquals(4, event.payload["minutes"])
    }

    @Test
    fun `empty snapshot yields zero minutes and idle app`() {
        val event = liveActivityPayload(emptyMap(), null)
        assertEquals("idle", event.payload["app"])
        assertEquals(0, event.payload["minutes"])
    }

    @Test
    fun `payload shape is exactly app and minutes`() {
        val event = liveActivityPayload(mapOf("com.a" to 1), "com.a")
        assertEquals(setOf("app", "minutes"), event.payload.keys)
        assertTrue(event.payload["app"] is String)
        assertTrue(event.payload["minutes"] is Int)
    }
}
