package com.familyshield.agent

import com.familyshield.agent.commands.CommandDispatcher
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

/** Pure-JVM tests for the bonus_time/wind_down minutes clamp (Features #10/#22). */
class CommandDispatcherMinutesTest {

    @Test
    fun `plain integer minutes are accepted`() {
        assertEquals(1, CommandDispatcher.parseMinutes("1"))
        assertEquals(30, CommandDispatcher.parseMinutes("30"))
        assertEquals(240, CommandDispatcher.parseMinutes("240"))
    }

    @Test
    fun `json-stringified number minutes are accepted`() {
        assertEquals(30, CommandDispatcher.parseMinutes("30.0"))
    }

    @Test
    fun `negative minutes clamp to the minimum`() {
        assertEquals(1, CommandDispatcher.parseMinutes("-5"))
        assertEquals(1, CommandDispatcher.parseMinutes("0"))
    }

    @Test
    fun `excessive minutes clamp to the maximum`() {
        assertEquals(240, CommandDispatcher.parseMinutes("99999"))
    }

    @Test
    fun `non-numeric or missing minutes are rejected`() {
        assertNull(CommandDispatcher.parseMinutes("abc"))
        assertNull(CommandDispatcher.parseMinutes(""))
        assertNull(CommandDispatcher.parseMinutes(null))
    }
}
