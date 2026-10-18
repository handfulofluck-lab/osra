package com.familyshield.agent.services

import com.familyshield.agent.services.LocationStartPolicy.Decision
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Issue #132: the shared rule for starting [LocationService] from a background context. Fine **or**
 * coarse location is the while-in-use grant; on API 29+ a location foreground service created from
 * the background also needs `ACCESS_BACKGROUND_LOCATION`, or Android 14+ refuses `startForeground()`
 * and the unmet `startForegroundService()` clock kills the process.
 */
class LocationStartPolicyTest {

    @Test
    fun `no location permission at all is refused with a reason`() {
        assertEquals(Decision.MISSING_LOCATION_PERMISSION, LocationStartPolicy.decide(false, false, false, 34))
        assertEquals(Decision.MISSING_LOCATION_PERMISSION, LocationStartPolicy.decide(false, false, true, 34))
        assertEquals(Decision.MISSING_LOCATION_PERMISSION, LocationStartPolicy.decide(false, false, false, 28))
        assertEquals("location_permission_missing", Decision.MISSING_LOCATION_PERMISSION.reason)
    }

    @Test
    fun `while-in-use permission alone is refused on Q and later`() {
        for (apiLevel in intArrayOf(29, 33, 34, 35)) {
            assertEquals(
                "fine only, API $apiLevel",
                Decision.MISSING_BACKGROUND_LOCATION,
                LocationStartPolicy.decide(true, false, false, apiLevel),
            )
            assertEquals(
                "coarse only, API $apiLevel",
                Decision.MISSING_BACKGROUND_LOCATION,
                LocationStartPolicy.decide(false, true, false, apiLevel),
            )
            assertEquals(
                "fine and coarse, API $apiLevel",
                Decision.MISSING_BACKGROUND_LOCATION,
                LocationStartPolicy.decide(true, true, false, apiLevel),
            )
        }
        assertEquals("background_location_missing", Decision.MISSING_BACKGROUND_LOCATION.reason)
    }

    @Test
    fun `fine or coarse plus the background grant starts`() {
        assertEquals(Decision.START, LocationStartPolicy.decide(true, false, true, 34))
        assertEquals(Decision.START, LocationStartPolicy.decide(false, true, true, 34))
        assertEquals(Decision.START, LocationStartPolicy.decide(true, true, true, 34))
        assertNull(Decision.START.reason)
    }

    @Test
    fun `pre-Q needs no background grant because the OS grants it implicitly`() {
        assertEquals(Decision.START, LocationStartPolicy.decide(true, false, false, 28))
        assertEquals(Decision.START, LocationStartPolicy.decide(false, true, false, 28))
    }

    @Test
    fun `shouldStart mirrors decide`() {
        assertTrue(LocationStartPolicy.shouldStart(true, false, true, 34))
        assertTrue(LocationStartPolicy.shouldStart(false, true, false, 28))
        assertFalse(LocationStartPolicy.shouldStart(true, false, false, 34))
        assertFalse(LocationStartPolicy.shouldStart(false, false, true, 34))
    }
}
