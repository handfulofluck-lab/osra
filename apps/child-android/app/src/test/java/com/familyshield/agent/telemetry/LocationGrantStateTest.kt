package com.familyshield.agent.telemetry

import com.familyshield.agent.services.LocationStartPolicy.Decision
import org.junit.Assert.assertEquals
import org.junit.Test

/**
 * Issue #221 (D1): the value the agent puts in `locationGrant` on every telemetry upload. The server
 * stores it and refuses a `locate_now` at the POST when it cannot work, so the mapping must be the
 * policy's own decision and the three strings must be the server contract
 * (`services/api/src/lib/locationGrant.ts`).
 */
class LocationGrantStateTest {

    @Test
    fun `no location permission reports none`() {
        assertEquals(LocationGrantState.NONE, LocationGrantState.classify(false, false, false, 34))
        assertEquals(LocationGrantState.NONE, LocationGrantState.classify(false, false, true, 34))
        assertEquals(LocationGrantState.NONE, LocationGrantState.classify(false, false, false, 28))
    }

    @Test
    fun `while-in-use only reports while_in_use on Q and later`() {
        for (apiLevel in intArrayOf(29, 33, 34, 35)) {
            assertEquals("fine only, API $apiLevel", LocationGrantState.WHILE_IN_USE, LocationGrantState.classify(true, false, false, apiLevel))
            assertEquals("coarse only, API $apiLevel", LocationGrantState.WHILE_IN_USE, LocationGrantState.classify(false, true, false, apiLevel))
            assertEquals("fine and coarse, API $apiLevel", LocationGrantState.WHILE_IN_USE, LocationGrantState.classify(true, true, false, apiLevel))
        }
    }

    @Test
    fun `fine or coarse plus the background grant reports background`() {
        assertEquals(LocationGrantState.BACKGROUND, LocationGrantState.classify(true, false, true, 34))
        assertEquals(LocationGrantState.BACKGROUND, LocationGrantState.classify(false, true, true, 34))
        assertEquals(LocationGrantState.BACKGROUND, LocationGrantState.classify(true, true, true, 34))
    }

    @Test
    fun `pre-Q while-in-use reports background because the policy starts from the background there`() {
        assertEquals(LocationGrantState.BACKGROUND, LocationGrantState.classify(true, false, false, 28))
        assertEquals(LocationGrantState.BACKGROUND, LocationGrantState.classify(false, true, false, 28))
    }

    @Test
    fun `report maps every policy decision, and the wire strings are the server contract`() {
        assertEquals("background", LocationGrantState.report(Decision.START))
        assertEquals("while_in_use", LocationGrantState.report(Decision.MISSING_BACKGROUND_LOCATION))
        assertEquals("none", LocationGrantState.report(Decision.MISSING_LOCATION_PERMISSION))
    }
}
