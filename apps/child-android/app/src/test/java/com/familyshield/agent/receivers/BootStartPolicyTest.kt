package com.familyshield.agent.receivers

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Issue #128: a `BOOT_COMPLETED` receiver runs with no visible activity, so a location foreground
 * service started there needs more than the while-in-use grant. Android 14+ refuses a location FGS
 * created from the background without `ACCESS_BACKGROUND_LOCATION`, and a service that is started
 * with `startForegroundService()` but never reaches `startForeground()` takes the process down with
 * `ForegroundServiceDidNotStartInTimeException`. The receiver therefore asks this policy first.
 */
class BootStartPolicyTest {

    @Test
    fun `no location permission at all does not request the service`() {
        assertFalse(BootStartPolicy.shouldStartLocationService(true, false, false, false, 34))
        assertFalse(BootStartPolicy.shouldStartLocationService(true, false, false, true, 34))
        assertFalse(BootStartPolicy.shouldStartLocationService(true, false, false, false, 28))
    }

    @Test
    fun `while-in-use permission alone at boot does not request the service on Q and later`() {
        assertFalse(BootStartPolicy.shouldStartLocationService(true, true, false, false, 34))
        assertFalse(BootStartPolicy.shouldStartLocationService(true, false, true, false, 34))
        assertFalse(BootStartPolicy.shouldStartLocationService(true, true, true, false, 34))
        assertFalse(BootStartPolicy.shouldStartLocationService(true, true, true, false, 29))
    }

    @Test
    fun `location granted including background requests the service`() {
        assertTrue(BootStartPolicy.shouldStartLocationService(true, true, false, true, 34))
        assertTrue(BootStartPolicy.shouldStartLocationService(true, false, true, true, 34))
        assertTrue(BootStartPolicy.shouldStartLocationService(true, true, true, true, 34))
    }

    @Test
    fun `pre-Q needs no background grant because the OS grants it implicitly`() {
        assertTrue(BootStartPolicy.shouldStartLocationService(true, true, false, false, 28))
        assertTrue(BootStartPolicy.shouldStartLocationService(true, false, true, false, 28))
    }

    /** Issue #472: a phone with no device row must not start the location service at boot, either. */
    @Test
    fun `an unpaired device does not start the service at boot`() {
        assertFalse(BootStartPolicy.shouldStartLocationService(false, true, true, true, 34))
    }
}
