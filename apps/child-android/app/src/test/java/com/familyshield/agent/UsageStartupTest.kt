package com.familyshield.agent

import com.familyshield.agent.data.UsageStartupSource
import com.familyshield.agent.data.planUsageStartup
import java.time.LocalDate
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/** Pure-JVM tests for the startup precedence between the saved snapshot and Room's events (#286). */
class UsageStartupTest {

    private val today = LocalDate.of(2026, 10, 21)

    @Test
    fun `the saved snapshot wins over the events left in Room`() {
        // The bypass: after an upload deletes the day's events, Room holds only the last window. Rebuilding
        // from it replaced ten minutes with nothing.
        val plan = planUsageStartup(
            savedMs = mapOf("com.a" to 600_000L),
            savedDate = today.toString(),
            today = today,
            roomEventCount = 3,
        )
        assertEquals(UsageStartupSource.SNAPSHOT, plan.source)
        assertEquals(mapOf("com.a" to 600_000L), plan.countersMs)
    }

    @Test
    fun `no snapshot falls back to the events`() {
        val plan = planUsageStartup(savedMs = null, savedDate = null, today = today, roomEventCount = 2)
        assertEquals(UsageStartupSource.ROOM_EVENTS, plan.source)
        assertTrue(plan.countersMs.isEmpty())
    }

    @Test
    fun `a snapshot from yesterday does not seed today`() {
        val plan = planUsageStartup(
            savedMs = mapOf("com.a" to 600_000L),
            savedDate = today.minusDays(1).toString(),
            today = today,
            roomEventCount = 4,
        )
        assertEquals(UsageStartupSource.ROOM_EVENTS, plan.source)
        assertTrue(plan.countersMs.isEmpty())
    }

    @Test
    fun `neither a snapshot nor events is an empty day`() {
        val plan = planUsageStartup(savedMs = null, savedDate = today.toString(), today = today, roomEventCount = 0)
        assertEquals(UsageStartupSource.EMPTY, plan.source)
    }
}
