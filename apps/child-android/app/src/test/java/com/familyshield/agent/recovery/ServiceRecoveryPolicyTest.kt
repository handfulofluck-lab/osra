package com.familyshield.agent.recovery

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Issue #1085: the plan the app follows after the OS killed it. Each row names the mutant it kills.
 *
 * The lesson these exist to prevent is a policy that restarts things on a device that has no family any
 * more: a de-linked or paused phone answers "nothing to do" to every question.
 */
class ServiceRecoveryPolicyTest {

    private fun state(
        isPaired: Boolean = true,
        consentPaused: Boolean = false,
        filterWanted: Boolean = true,
        tunnelRunning: Boolean = true,
        locationMayStart: Boolean = true,
        locationRunning: Boolean = true,
        lockActive: Boolean = false,
        accessibilityEnabled: Boolean = true,
        accessibilityBound: Boolean = true,
    ) = ServiceRecoveryPolicy.State(
        isPaired = isPaired,
        consentPaused = consentPaused,
        filterWanted = filterWanted,
        tunnelRunning = tunnelRunning,
        locationMayStart = locationMayStart,
        locationRunning = locationRunning,
        lockActive = lockActive,
        accessibilityEnabled = accessibilityEnabled,
        accessibilityBound = accessibilityBound,
    )

    @Test
    fun `a healthy phone has nothing to do`() {
        val plan = ServiceRecoveryPolicy.plan(state())
        assertTrue(plan.isEmpty)
        assertEquals(emptyList<ServiceRecoveryPolicy.Gap>(), plan.gaps)
    }

    @Test
    fun `the killed-process shape restarts the filter and the location service and names both`() {
        // The child-2 shape: the process died, so the tunnel is down and no location service is running.
        val plan = ServiceRecoveryPolicy.plan(state(tunnelRunning = false, locationRunning = false))
        assertTrue(plan.restartFilter)
        assertTrue(plan.restartLocation)
        assertEquals(
            listOf(ServiceRecoveryPolicy.Gap.FILTER_DOWN, ServiceRecoveryPolicy.Gap.LOCATION_DOWN),
            plan.gaps,
        )
    }

    @Test
    fun `an unpaired phone is never recovered and never reported`() {
        // Mutant: dropping the isPaired guard restarts a tunnel on a device whose family deleted it (#472).
        val plan = ServiceRecoveryPolicy.plan(
            state(isPaired = false, tunnelRunning = false, locationRunning = false, lockActive = true, accessibilityEnabled = false),
        )
        assertTrue(plan.isEmpty)
        assertEquals(emptyList<ServiceRecoveryPolicy.Gap>(), plan.gaps)
    }

    @Test
    fun `a paused phone is not recovered either`() {
        val plan = ServiceRecoveryPolicy.plan(state(consentPaused = true, tunnelRunning = false, locationRunning = false))
        assertTrue(plan.isEmpty)
    }

    @Test
    fun `a filter the parent never asked for is not started`() {
        // Mutant: restarting whenever the tunnel is down would resurrect a filter a parent switched off.
        val plan = ServiceRecoveryPolicy.plan(state(filterWanted = false, tunnelRunning = false))
        assertFalse(plan.restartFilter)
        assertFalse(plan.gaps.contains(ServiceRecoveryPolicy.Gap.FILTER_DOWN))
    }

    @Test
    fun `location is not started when the background-start policy refuses`() {
        // The field is LocationStartPolicy's verdict, not "a grant exists": on API 29+ a while-in-use grant
        // is a refusal, because `startForegroundService` from a worker would crash (Hydrogen, #1098).
        val plan = ServiceRecoveryPolicy.plan(state(locationMayStart = false, locationRunning = false))
        assertFalse(plan.restartLocation)
        assertFalse(plan.gaps.contains(ServiceRecoveryPolicy.Gap.LOCATION_DOWN))
    }

    @Test
    fun `an active lock is shown again even when everything else is up`() {
        val plan = ServiceRecoveryPolicy.plan(state(lockActive = true))
        assertTrue(plan.showLock)
        assertEquals(listOf(ServiceRecoveryPolicy.Gap.LOCK_NOT_SHOWN), plan.gaps)
        assertFalse(plan.restartFilter)
        assertFalse(plan.restartLocation)
    }

    @Test
    fun `a service enabled in Settings but not bound here is a distinct gap`() {
        // #1085 requirement 2, Hydrogen's #1098 review: after MIUI's kill Settings still lists the service
        // while this process has it unbound. Mutant: reporting ACCESSIBILITY_OFF sends the parent to a switch
        // that already reads "on" — the silent failure #1085 exists to end.
        val plan = ServiceRecoveryPolicy.plan(state(accessibilityBound = false))
        assertEquals(listOf(ServiceRecoveryPolicy.Gap.ACCESSIBILITY_UNBOUND), plan.gaps)
        assertFalse(plan.restartFilter)
        assertFalse(plan.restartLocation)
        assertFalse(plan.showLock)
    }

    @Test
    fun `a service that is off is off, not unbound as well`() {
        // One gap per cause: a parent who sees both would not know which switch to trust.
        val plan = ServiceRecoveryPolicy.plan(state(accessibilityEnabled = false, accessibilityBound = false))
        assertEquals(listOf(ServiceRecoveryPolicy.Gap.ACCESSIBILITY_OFF), plan.gaps)
    }

    @Test
    fun `an accessibility service that is switched off is reported but never restarted`() {
        // Android will not start it for us; a plan that claims to would be a promise the phone cannot keep.
        val plan = ServiceRecoveryPolicy.plan(state(accessibilityEnabled = false))
        assertEquals(listOf(ServiceRecoveryPolicy.Gap.ACCESSIBILITY_OFF), plan.gaps)
        assertFalse(plan.restartFilter)
        assertFalse(plan.restartLocation)
        assertFalse(plan.showLock)
    }
}
