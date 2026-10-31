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
        assertEquals(Decision.MISSING_LOCATION_PERMISSION, LocationStartPolicy.decide(true, false, false, false, 34))
        assertEquals(Decision.MISSING_LOCATION_PERMISSION, LocationStartPolicy.decide(true, false, false, true, 34))
        assertEquals(Decision.MISSING_LOCATION_PERMISSION, LocationStartPolicy.decide(true, false, false, false, 28))
        assertEquals("location_permission_missing", Decision.MISSING_LOCATION_PERMISSION.reason)
    }

    @Test
    fun `while-in-use permission alone is refused on Q and later`() {
        for (apiLevel in intArrayOf(29, 33, 34, 35)) {
            assertEquals(
                "fine only, API $apiLevel",
                Decision.MISSING_BACKGROUND_LOCATION,
                LocationStartPolicy.decide(true, true, false, false, apiLevel),
            )
            assertEquals(
                "coarse only, API $apiLevel",
                Decision.MISSING_BACKGROUND_LOCATION,
                LocationStartPolicy.decide(true, false, true, false, apiLevel),
            )
            assertEquals(
                "fine and coarse, API $apiLevel",
                Decision.MISSING_BACKGROUND_LOCATION,
                LocationStartPolicy.decide(true, true, true, false, apiLevel),
            )
        }
        assertEquals("background_location_missing", Decision.MISSING_BACKGROUND_LOCATION.reason)
    }

    @Test
    fun `fine or coarse plus the background grant starts`() {
        assertEquals(Decision.START, LocationStartPolicy.decide(true, true, false, true, 34))
        assertEquals(Decision.START, LocationStartPolicy.decide(true, false, true, true, 34))
        assertEquals(Decision.START, LocationStartPolicy.decide(true, true, true, true, 34))
        assertNull(Decision.START.reason)
    }

    @Test
    fun `pre-Q needs no background grant because the OS grants it implicitly`() {
        assertEquals(Decision.START, LocationStartPolicy.decide(true, true, false, false, 28))
        assertEquals(Decision.START, LocationStartPolicy.decide(true, false, true, false, 28))
    }

    @Test
    fun `shouldStart mirrors decide`() {
        assertTrue(LocationStartPolicy.shouldStart(true, true, false, true, 34))
        assertTrue(LocationStartPolicy.shouldStart(true, false, true, false, 28))
        assertFalse(LocationStartPolicy.shouldStart(true, true, false, false, 34))
        assertFalse(LocationStartPolicy.shouldStart(true, false, false, true, 34))
    }

    /**
     * Issue #472: an unlinked phone has no child to locate and no family to report to. This is checked
     * **before** the grants, because "grant more permissions" is the wrong thing to tell a family that
     * has deleted the account, and because the unlink notice says the app can now be uninstalled.
     *
     * Mutant: delete `if (!isPaired) return Decision.UNPAIRED` from `decide` and this row gets START.
     */
    @Test
    fun `an unpaired device is refused as not_paired before any grant is read`() {
        assertEquals(Decision.UNPAIRED, LocationStartPolicy.decide(false, true, true, true, 34))
        assertEquals("not_paired", Decision.UNPAIRED.reason)
        assertFalse(LocationStartPolicy.shouldStart(false, true, true, true, 34))
        // The reason must not shadow a real permission problem on a paired phone.
        assertEquals(
            Decision.MISSING_LOCATION_PERMISSION,
            LocationStartPolicy.decide(true, false, false, false, 34),
        )
    }
}
