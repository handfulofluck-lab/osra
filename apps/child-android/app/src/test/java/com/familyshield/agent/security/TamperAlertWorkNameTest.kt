package com.familyshield.agent.security

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotEquals
import org.junit.Test

/**
 * Issue #227 D1 (Claude's review of #235): the worker used one unique work name per alert type, so
 * enqueueing the next window's alert **cancelled the previous window's pending retry**. A child who
 * kept trying while the phone was offline — the exact case where attempts pile up — had every burst
 * but the last dropped: window A stayed at its old count and its offline attempts never arrived.
 *
 * The name is now per window for the guard type only. REPLACE still coalesces inside a window
 * (the newest count wins), and a new window cannot cancel an older window's retry.
 */
class TamperAlertWorkNameTest {

    @Test
    fun `two counts in the same window share one work name`() {
        val first = TamperAlertWorker.uniqueWorkName(TamperAlertWorker.TYPE_GUARD_TRIGGERED, 1_000L)
        val later = TamperAlertWorker.uniqueWorkName(TamperAlertWorker.TYPE_GUARD_TRIGGERED, 1_000L)

        assertEquals("REPLACE must coalesce inside one window", first, later)
    }

    @Test
    fun `a new window gets its own work name, so the older window's retry survives`() {
        val windowA = TamperAlertWorker.uniqueWorkName(TamperAlertWorker.TYPE_GUARD_TRIGGERED, 1_000L)
        val windowB = TamperAlertWorker.uniqueWorkName(TamperAlertWorker.TYPE_GUARD_TRIGGERED, 301_000L)

        assertNotEquals(
            "cancelling the old name is exactly the D1 defect",
            windowA,
            windowB,
        )
    }

    @Test
    fun `every other alert type keeps the single per-type name`() {
        // device_admin_removed already has its own idempotency key (#225); it must not start
        // accumulating one work name per timestamp.
        assertEquals(
            "tamper_alert_${TamperAlertWorker.TYPE_ADMIN_REMOVED}",
            TamperAlertWorker.uniqueWorkName(TamperAlertWorker.TYPE_ADMIN_REMOVED, 1_000L),
        )
        assertEquals(
            "tamper_alert_${TamperAlertWorker.TYPE_ADMIN_REMOVED}",
            TamperAlertWorker.uniqueWorkName(TamperAlertWorker.TYPE_ADMIN_REMOVED, 0L),
        )
    }

    @Test
    fun `a legacy guard job with no window input keeps the old name`() {
        // A TYPE_GUARD_TRIGGERED job enqueued by a pre-#227 build carries windowStartMs = 0; it must
        // still coalesce on the old name rather than invent one per timestamp.
        assertEquals(
            "tamper_alert_${TamperAlertWorker.TYPE_GUARD_TRIGGERED}",
            TamperAlertWorker.uniqueWorkName(TamperAlertWorker.TYPE_GUARD_TRIGGERED, 0L),
        )
    }
}
