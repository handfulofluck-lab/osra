package com.familyshield.agent.security

import com.familyshield.agent.receivers.AccessibilityOffPolicy
import org.junit.Assert.assertEquals
import org.junit.Test
import org.junit.runner.RunWith
import org.junit.runners.Parameterized

/**
 * Issue #225, table-driven by permission: every grant that has a tamper-alert site is listed here
 * with the rule that site applies. The three observations per row are the reviewer's cases:
 *
 *  - off on the first observation (never granted) -> 0 alerts;
 *  - recorded granted -> revoked -> exactly 1 alert;
 *  - off -> off -> 0 alerts.
 *
 * `AccessibilityOffReceiver.checkOnce` uses [AccessibilityOffPolicy.shouldAlertOnObservation] (which
 * delegates to [PermissionObservationPolicy]); `LocationService.overlayCheckOnce` uses
 * [PermissionObservationPolicy] directly. A new permission with an alert site belongs in this table.
 */
@RunWith(Parameterized::class)
class PerPermissionEdgeTriggerTableTest(
    private val permission: String,
    private val shouldAlert: (Boolean?, Boolean) -> Boolean,
) {

    companion object {
        @JvmStatic
        @Parameterized.Parameters(name = "{0}")
        fun permissions(): List<Array<Any>> = listOf(
            arrayOf<Any>("accessibility", AccessibilityOffPolicy::shouldAlertOnObservation),
            arrayOf<Any>("overlay", PermissionObservationPolicy::shouldAlertOnObservation),
        )
    }

    @Test
    fun `off on first observation raises no alert`() {
        assertEquals("$permission: first observation off must be silent", 0, alertsFor(false))
    }

    @Test
    fun `recorded on then off raises exactly one alert`() {
        assertEquals("$permission: granted -> revoked is one alert", 1, alertsFor(true, false))
    }

    @Test
    fun `off then off raises no alert`() {
        assertEquals("$permission: off -> off must stay silent", 0, alertsFor(false, false))
    }

    /**
     * Replays [grants] through the permission's rule, recording each observation the way the alert
     * sites do: the new state is recorded when no alert fires, and the revoked state is recorded
     * after the (successful) alert POST.
     */
    private fun alertsFor(vararg grants: Boolean): Int {
        var recorded: Boolean? = null
        var alerts = 0
        for (grantedNow in grants) {
            if (shouldAlert(recorded, grantedNow)) {
                alerts += 1
                recorded = false
            } else {
                recorded = grantedNow
            }
        }
        return alerts
    }
}
