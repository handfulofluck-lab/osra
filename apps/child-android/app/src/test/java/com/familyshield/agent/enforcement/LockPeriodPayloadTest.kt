package com.familyshield.agent.enforcement

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

/** #830: the one `lock_period` row the parent's activity report reads. */
class LockPeriodPayloadTest {

    private val iso: (Long) -> String = { "t$it" }

    @Test
    fun `a closed period carries start, end, attempts and mode`() {
        val payload = LockPeriodTracker.payload(
            LockPeriodTracker.Period(startedAtMs = 10, mode = "locked", attempts = 4, endedAtMs = 99),
            iso,
        )
        assertEquals("t10", payload["startedAt"])
        assertEquals("t99", payload["endedAt"])
        assertEquals(4, payload["attempts"])
        assertEquals("locked", payload["mode"])
    }

    @Test
    fun `a period left open by a process death has no end time`() {
        val payload = LockPeriodTracker.payload(
            LockPeriodTracker.Period(startedAtMs = 10, mode = "paused", attempts = 0, endedAtMs = null),
            iso,
        )
        assertNull(payload["endedAt"])
        assertEquals(0, payload["attempts"])
    }
}
