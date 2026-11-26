package com.familyshield.agent.commands

import com.familyshield.agent.security.ParentPinStore.SetPrehashedResult
import org.junit.Assert.assertEquals
import org.junit.Test

/** #1108: `set_parent_pin` hands the hash to the store and acks what the store did. */
class ParentPinCommandTest {

    @Test
    fun `passes the pinHash field through and acks ok when it is stored`() {
        var seen: String? = "unset"
        val outcome = ParentPinCommand.apply(mapOf("pinHash" to "h")) { seen = it; SetPrehashedResult.STORED }
        assertEquals("h", seen)
        assertEquals(CommandOutcome.Applied(), outcome)
    }

    @Test
    fun `a missing field reaches the store as null, which refuses it`() {
        var seen: String? = "unset"
        val outcome = ParentPinCommand.apply(emptyMap()) { seen = it; SetPrehashedResult.INVALID_SHAPE }
        assertEquals(null, seen)
        assertEquals(CommandOutcome.Refused(ParentPinCommand.REASON_INVALID_PIN_HASH), outcome)
    }

    @Test
    fun `a write that did not land is a failed ack with its own reason`() {
        val outcome = ParentPinCommand.apply(mapOf("pinHash" to "h")) { SetPrehashedResult.WRITE_FAILED }
        assertEquals(CommandOutcome.Refused(ParentPinCommand.REASON_PIN_WRITE_FAILED), outcome)
    }
}
