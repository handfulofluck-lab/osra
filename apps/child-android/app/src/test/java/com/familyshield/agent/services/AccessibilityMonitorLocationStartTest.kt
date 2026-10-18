package com.familyshield.agent.services

import com.familyshield.agent.services.LocationStartPolicy.Decision
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

/**
 * Issue #132: `AccessibilityMonitorService.ensureLocationServiceRunning()` used to start the location
 * foreground service on a fine/coarse check alone, so on Android 14+ a device that had not granted
 * "Location (allow all the time)" could lose the agent to
 * `ForegroundServiceDidNotStartInTimeException` — the same class of failure #128 fixed at boot.
 * This is the call site's decision, kept pure because an `AccessibilityService` cannot be
 * instantiated in a plain JVM test (`BootStartPolicyTest` style).
 */
class AccessibilityMonitorLocationStartTest {

    @Test
    fun `while-in-use location alone does not start the service on Android 14`() {
        assertEquals(
            Decision.MISSING_BACKGROUND_LOCATION,
            AccessibilityMonitorService.locationStartDecision(
                isServiceRunning = false,
                paired = true,
                hasFineLocation = true,
                hasCoarseLocation = false,
                hasBackgroundLocation = false,
                apiLevel = 34,
            ),
        )
        assertEquals(
            Decision.MISSING_BACKGROUND_LOCATION,
            AccessibilityMonitorService.locationStartDecision(
                isServiceRunning = false,
                paired = true,
                hasFineLocation = false,
                hasCoarseLocation = true,
                hasBackgroundLocation = false,
                apiLevel = 29,
            ),
        )
    }

    @Test
    fun `the background grant starts the service`() {
        assertEquals(
            Decision.START,
            AccessibilityMonitorService.locationStartDecision(
                isServiceRunning = false,
                paired = true,
                hasFineLocation = true,
                hasCoarseLocation = false,
                hasBackgroundLocation = true,
                apiLevel = 34,
            ),
        )
    }

    @Test
    fun `pre-Q starts on the while-in-use grant`() {
        assertEquals(
            Decision.START,
            AccessibilityMonitorService.locationStartDecision(
                isServiceRunning = false,
                paired = true,
                hasFineLocation = true,
                hasCoarseLocation = false,
                hasBackgroundLocation = false,
                apiLevel = 28,
            ),
        )
    }

    @Test
    fun `missing location is refused rather than started and stopped`() {
        assertEquals(
            Decision.MISSING_LOCATION_PERMISSION,
            AccessibilityMonitorService.locationStartDecision(
                isServiceRunning = false,
                paired = true,
                hasFineLocation = false,
                hasCoarseLocation = false,
                hasBackgroundLocation = true,
                apiLevel = 34,
            ),
        )
    }

    @Test
    fun `an already running service or an unpaired device is left alone`() {
        assertNull(
            AccessibilityMonitorService.locationStartDecision(
                isServiceRunning = true,
                paired = true,
                hasFineLocation = true,
                hasCoarseLocation = true,
                hasBackgroundLocation = true,
                apiLevel = 34,
            ),
        )
        assertNull(
            AccessibilityMonitorService.locationStartDecision(
                isServiceRunning = false,
                paired = false,
                hasFineLocation = true,
                hasCoarseLocation = true,
                hasBackgroundLocation = true,
                apiLevel = 34,
            ),
        )
    }
}
