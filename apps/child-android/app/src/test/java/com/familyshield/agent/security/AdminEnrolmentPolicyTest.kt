package com.familyshield.agent.security

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** Issue #186: classify the dead end after the system sheet, without claiming a self-heal. */
class AdminEnrolmentPolicyTest {

    private fun classify(
        sheetReturned: Boolean = true,
        isAdminActive: Boolean = false,
        isDeviceOwner: Boolean = false,
        knoxAvailable: Boolean = true,
    ) = AdminEnrolmentPolicy.classify(sheetReturned, isAdminActive, isDeviceOwner, knoxAvailable)

    @Test
    fun `sheet returned with no active admin on Samsung is the stale Knox state`() {
        assertEquals(EnrolmentOutcome.STALE_KNOX_ADMIN, classify())
    }

    @Test
    fun `an active admin is protected, never stale`() {
        assertEquals(
            EnrolmentOutcome.PROTECTED,
            classify(isAdminActive = true, knoxAvailable = true),
        )
    }

    @Test
    fun `a device owner is protected, never stale`() {
        assertEquals(
            EnrolmentOutcome.PROTECTED,
            classify(isAdminActive = false, isDeviceOwner = true, knoxAvailable = true),
        )
    }

    @Test
    fun `before the sheet returns nothing is classified`() {
        assertEquals(
            EnrolmentOutcome.NOT_ATTEMPTED,
            classify(sheetReturned = false, knoxAvailable = true),
        )
    }

    @Test
    fun `a failed activation without Knox is an ordinary not-granted result`() {
        assertEquals(
            EnrolmentOutcome.NOT_GRANTED,
            classify(knoxAvailable = false),
        )
    }

    @Test
    fun `the stale message names the cause, the Settings route and the app's limit`() {
        val message = AdminEnrolmentMessages.forOutcome(EnrolmentOutcome.STALE_KNOX_ADMIN)

        assertNotNull(message)
        val stale = message!!
        assertTrue(stale.body.contains("Admin is already added"))
        assertTrue(stale.recovery.contains("Device admin apps"))
        assertTrue(stale.recovery.contains("factory reset"))
        assertEquals("Open device admin settings", stale.action)
    }

    @Test
    fun `normal outcomes get no stale message`() {
        for (outcome in EnrolmentOutcome.values().filter { it != EnrolmentOutcome.STALE_KNOX_ADMIN }) {
            assertNull("$outcome must not show the stale-Knox message", AdminEnrolmentMessages.forOutcome(outcome))
        }
    }
}
