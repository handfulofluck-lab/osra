package com.familyshield.agent.comms

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Issue #229: a later READ_CALL_LOG/READ_SMS grant must register the observer it was refused at
 * start. `start()` used to set one `started` flag before registering, so the failed registration was
 * never retried until the process restarted.
 *
 * The Android registration itself needs a device; the decision is pure and held here. The wiring
 * (`start()` → `registerObservers()` → each flag, `onPermissionsChanged()` from the three call sites)
 * is pinned by [CommsGrantWiringTest].
 */
class CommsObserverPolicyTest {

    @Test
    fun `registration is exactly the cell where a new grant meets no observer`() {
        val cases = listOf(
            Triple(true, false, true), // granted now, never registered: the retry
            Triple(true, true, false), // already watching: do not register twice
            Triple(false, false, false), // still denied: nothing to register
            Triple(false, true, false), // denied later: the harvest guard handles it
        )

        for ((granted, alreadyRegistered, expected) in cases) {
            assertEquals(
                "granted=$granted alreadyRegistered=$alreadyRegistered",
                expected,
                CommsObserverPolicy.shouldRegister(granted, alreadyRegistered),
            )
        }
    }

    @Test
    fun `a stream refused at start registers on the first later grant, once`() {
        var registered = false

        assertFalse("boot with the permission denied", CommsObserverPolicy.shouldRegister(permissionGranted = false, alreadyRegistered = registered))

        val onGrant = CommsObserverPolicy.shouldRegister(permissionGranted = true, alreadyRegistered = registered)
        assertTrue("the later grant must retry the registration", onGrant)
        if (onGrant) registered = true

        assertFalse(
            "onPermissionsChanged() runs on every resume and every five minutes; a second registration " +
                "would deliver every change twice",
            CommsObserverPolicy.shouldRegister(permissionGranted = true, alreadyRegistered = registered),
        )
    }
}
