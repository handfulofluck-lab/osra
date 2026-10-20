package com.familyshield.agent.setup

import com.familyshield.agent.services.LocationStartPolicy
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Issue #221 D3: the pairing status screen claimed "✓ Location tracking: Active" with a while-in-use
 * grant only, and a Locate then failed with `background_location_missing`.
 *
 * The rule is [LocationStartPolicy.decide] (the same judgement every background start goes through)
 * plus the service state, turned into one line by [LocationStatusPolicy]. These cases pin that the
 * tick appears only for the "allow all the time" state.
 */
class LocationStatusPolicyTest {

    private fun status(
        fine: Boolean = true,
        coarse: Boolean = true,
        background: Boolean = true,
        apiLevel: Int = 34,
        running: Boolean = true,
    ) = LocationStatusPolicy.classify(
        LocationStartPolicy.decide(
            hasFineLocation = fine,
            hasCoarseLocation = coarse,
            hasBackgroundLocation = background,
            apiLevel = apiLevel,
        ),
        serviceRunning = running,
    )

    @Test
    fun `a while-in-use grant never shows the active tick, even while the service runs`() {
        val whileInUse = status(background = false, running = true)

        assertEquals(LocationStatus.MISSING_BACKGROUND, whileInUse)
        assertFalse("the tick is a lie without 'allow all the time'", LocationStatusPolicy.showsActiveTick(whileInUse))
        assertTrue(LocationStatusPolicy.line(whileInUse).contains("Allow all the time"))
        assertEquals("Allow location all the time", LocationStatusPolicy.actionLabel(whileInUse))
    }

    @Test
    fun `background grant and a running service is the only active state`() {
        val active = status(background = true, running = true)

        assertEquals(LocationStatus.ACTIVE, active)
        assertTrue(LocationStatusPolicy.showsActiveTick(active))
        assertTrue(LocationStatusPolicy.line(active).startsWith("\n✓"))
        assertEquals(null, LocationStatusPolicy.actionLabel(active))
    }

    @Test
    fun `background grant with a stopped service is actionable, not active`() {
        val stopped = status(background = true, running = false)

        assertEquals(LocationStatus.SERVICE_STOPPED, stopped)
        assertFalse(LocationStatusPolicy.showsActiveTick(stopped))
        assertEquals("Start location service", LocationStatusPolicy.actionLabel(stopped))
    }

    @Test
    fun `no location permission asks for the grant first, whatever the background flag says`() {
        val missing = status(fine = false, coarse = false, background = false, running = false)

        assertEquals(LocationStatus.MISSING_PERMISSION, missing)
        assertFalse(LocationStatusPolicy.showsActiveTick(missing))
        assertNotNull(LocationStatusPolicy.actionLabel(missing))
    }

    @Test
    fun `before Android 10 a while-in-use grant is a background grant`() {
        // Pre-Q has no separate background permission, so LocationStartPolicy returns START and the
        // server is never told 'while_in_use'. The screen must therefore show Active, not a warning
        // the user cannot resolve.
        val preQ = status(background = false, apiLevel = 28, running = true)

        assertEquals(LocationStatus.ACTIVE, preQ)
        assertTrue(LocationStatusPolicy.showsActiveTick(preQ))
    }

    @Test
    fun `a coarse-only grant is while-in-use, not missing`() {
        val coarseOnly = status(fine = false, coarse = true, background = false)

        assertEquals(LocationStatus.MISSING_BACKGROUND, coarseOnly)
    }
}
