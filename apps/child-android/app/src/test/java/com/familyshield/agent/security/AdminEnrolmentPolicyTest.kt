package com.familyshield.agent.security

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** Issues #186 and #188: classify the dead end from evidence, never from Knox merely existing. */
class AdminEnrolmentPolicyTest {

    private fun classify(
        sheetReturned: Boolean = true,
        isAdminActive: Boolean = false,
        isDeviceOwner: Boolean = false,
        knoxAvailable: Boolean = true,
        alreadyAddedRefusal: Boolean = false,
    ) = AdminEnrolmentPolicy.classify(sheetReturned, isAdminActive, isDeviceOwner, knoxAvailable, alreadyAddedRefusal)

    @Test
    fun `a returned sheet with no active admin on Samsung is an ordinary not-granted result`() {
        // #188: a parent who backs out of the sheet must not be told that Knox holds a stale record.
        assertEquals(EnrolmentOutcome.NOT_GRANTED, classify())
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
            classify(knoxAvailable = false, alreadyAddedRefusal = true),
        )
    }

    @Test
    fun `an activation refused as already added shows the stale-record warning`() {
        // #188: the refusal itself is the evidence; this is the only path to STALE_KNOX_ADMIN.
        assertEquals(
            EnrolmentOutcome.STALE_KNOX_ADMIN,
            classify(alreadyAddedRefusal = true),
        )
        assertNotNull(AdminEnrolmentMessages.forOutcome(EnrolmentOutcome.STALE_KNOX_ADMIN))
    }

    @Test
    fun `the refusal shape is a cancelled sheet within a second`() {
        assertTrue(AdminEnrolmentPolicy.isAlreadyAddedRefusal(resultOk = false, elapsedSinceLaunchMs = 250))
        assertFalse(AdminEnrolmentPolicy.isAlreadyAddedRefusal(resultOk = false, elapsedSinceLaunchMs = 3_000))
        assertFalse(AdminEnrolmentPolicy.isAlreadyAddedRefusal(resultOk = true, elapsedSinceLaunchMs = 250))
    }

    @Test
    fun `a parent removal followed by a successful re-activation shows no stale warning`() {
        // The parent-PIN removal leaves the tier NONE and the flag set: the screen may say the
        // removal was deliberate, but it must not claim a stuck record.
        assertEquals(
            ProtectionStatusNote.REMOVED_BY_PARENT,
            AdminEnrolmentPolicy.statusNote(ProtectionTier.NONE, adminRemovedByParent = true),
        )

        // The parent taps Activate and the sheet returns with the admin active.
        val reactivated = classify(isAdminActive = true, knoxAvailable = true, alreadyAddedRefusal = false)

        assertEquals(EnrolmentOutcome.PROTECTED, reactivated)
        assertTrue("a successful activation clears the parent-removal flag", AdminEnrolmentPolicy.clearsParentRemoval(reactivated))
        assertNull("no stale-record text after a successful re-activation", AdminEnrolmentMessages.forOutcome(reactivated))
        assertEquals(
            ProtectionStatusNote.NONE,
            AdminEnrolmentPolicy.statusNote(ProtectionTier.ADMIN, adminRemovedByParent = false),
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
