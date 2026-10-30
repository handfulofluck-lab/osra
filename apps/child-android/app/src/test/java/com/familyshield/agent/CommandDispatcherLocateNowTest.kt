package com.familyshield.agent

import com.familyshield.agent.commands.CommandDispatcher
import com.familyshield.agent.services.LocationStartPolicy.Decision
import org.junit.Assert.assertEquals
import org.junit.Test

/**
 * Issue #132: `CommandDispatcher.locateNow()` started `LocationService` on a fine/coarse check alone.
 * From a poll or FCM context that is a background start, so on Android 10+ without
 * `ACCESS_BACKGROUND_LOCATION` it is a location FGS the app may not hold: Android 14+ refuses
 * `startForeground()` and `ForegroundServiceDidNotStartInTimeException` takes the process down — or,
 * as measured for #132, `locate_now` simply never produces a fix and the parent is told nothing.
 *
 * The refusal reason is part of the contract: it is sent as the `failed` command ack's
 * `detail.reason`, which the parent reads in `/v1/devices/:id/commands/history`.
 */
class CommandDispatcherLocateNowTest {

    @Test
    fun `locate_now without the background grant is refused with background_location_missing`() {
        val decision = CommandDispatcher.locateNowDecision(
            isPaired = true,
            hasFineLocation = true,
            hasCoarseLocation = false,
            hasBackgroundLocation = false,
            apiLevel = 34,
        )
        assertEquals(Decision.MISSING_BACKGROUND_LOCATION, decision)
        assertEquals("background_location_missing", decision.reason)
    }

    @Test
    fun `coarse-only while-in-use is refused the same way`() {
        val decision = CommandDispatcher.locateNowDecision(true, true, false, false, 29)
        assertEquals(Decision.MISSING_BACKGROUND_LOCATION, decision)
        assertEquals("background_location_missing", decision.reason)
    }

    @Test
    fun `locate_now with the background grant is allowed`() {
        assertEquals(
            Decision.START,
            CommandDispatcher.locateNowDecision(
                isPaired = true,
                hasFineLocation = true,
                hasCoarseLocation = true,
                hasBackgroundLocation = true,
                apiLevel = 34,
            ),
        )
    }

    @Test
    fun `locate_now without any location grant is refused with location_permission_missing`() {
        val decision = CommandDispatcher.locateNowDecision(true, false, false, false, 34)
        assertEquals(Decision.MISSING_LOCATION_PERMISSION, decision)
        assertEquals("location_permission_missing", decision.reason)
    }

    @Test
    fun `pre-Q locate_now needs no background grant`() {
        assertEquals(Decision.START, CommandDispatcher.locateNowDecision(true, true, false, false, 28))
    }
}
