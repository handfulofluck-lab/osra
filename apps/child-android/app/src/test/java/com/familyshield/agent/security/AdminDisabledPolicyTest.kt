package com.familyshield.agent.security

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Issue #188 follow-up: the decision [GuardianAdminReceiver.onDisabled] applies when the OS reports
 * the admin gone. Device-admin removal is asynchronous, so the old `isAdminActive()` check at the end
 * of `DeviceAdminManager.removeAdmin()` ran before the removal landed and never recorded the parent's
 * deliberate removal.
 *
 * These cases assert the pure decision and its declared effects. The `SharedPreferences` writes
 * themselves happen in the receiver and are not exercised here — the repo has JUnit 4 only (no
 * Robolectric, no androidTest source set).
 */
class AdminDisabledPolicyTest {

    private fun classify(nowMs: Long, sanctionedUntilMs: Long) =
        AdminDisabledPolicy.classify(nowMs = nowMs, sanctionedUntilMs = sanctionedUntilMs)

    @Test
    fun `a removal inside the sanctioned window records the parent removal and raises no alert`() {
        val now = 1_000_000L
        val outcome = classify(nowMs = now, sanctionedUntilMs = now + 60_000L)

        assertEquals(AdminDisabledOutcome.SANCTIONED_PARENT_REMOVAL, outcome)
        assertTrue("the deliberate removal is remembered", outcome.recordsParentRemoval)
        assertFalse("no tamper alert for a parent removal", outcome.marksAdminDisabledPending)
        assertFalse("nothing is enqueued as a tamper alert", outcome.enqueuesExpeditedAlert)
    }

    @Test
    fun `a removal outside the sanctioned window raises the pending alert and records no parent removal`() {
        val now = 1_000_000L
        val outcome = classify(nowMs = now, sanctionedUntilMs = now - 1L)

        assertEquals(AdminDisabledOutcome.TAMPER_ALERT, outcome)
        assertTrue("the next poll still alerts", outcome.marksAdminDisabledPending)
        assertTrue("the alert is enqueued now", outcome.enqueuesExpeditedAlert)
        assertFalse("an out-of-band removal is never the parent's", outcome.recordsParentRemoval)
    }

    @Test
    fun `the window is exclusive — exactly at its end the removal is a tamper alert`() {
        val now = 1_000_000L
        val outcome = classify(nowMs = now, sanctionedUntilMs = now)

        assertEquals(AdminDisabledOutcome.TAMPER_ALERT, outcome)
        assertFalse(outcome.recordsParentRemoval)
    }

    @Test
    fun `a device that was never sanctioned alerts on every removal`() {
        val outcome = classify(nowMs = 1_000_000L, sanctionedUntilMs = 0L)

        assertEquals(AdminDisabledOutcome.TAMPER_ALERT, outcome)
        assertTrue(outcome.marksAdminDisabledPending)
        assertTrue(outcome.enqueuesExpeditedAlert)
        assertFalse(outcome.recordsParentRemoval)
    }
}
