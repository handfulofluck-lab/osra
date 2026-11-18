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

    /**
     * osra-security#29, second half: the unbind alert is raised from the service itself, so the parent does not wait
     * for the 60-second poll — and hears at all on a phone where the location grant is off and the poll never runs.
     *
     * Mutant: drop the `enqueue(... TYPE_ACCESSIBILITY_OFF ...)` from `onUnbind` → [the unbind raises its own alert
     * at once] goes red, and nothing else does.
     */
    @Test
    fun `the unbind raises its own alert at once`() {
        val source = java.io.File(System.getProperty("user.dir") ?: ".").let { wd ->
            listOf(
                java.io.File(wd, "src/main/java/com/familyshield/agent/services/AccessibilityMonitorService.kt"),
                java.io.File(wd, "app/src/main/java/com/familyshield/agent/services/AccessibilityMonitorService.kt"),
            ).firstOrNull { it.isFile }?.readText() ?: error("service source not found below ${wd.path}")
        }
        val unbind = source.substringAfter("override fun onUnbind(", missingDelimiterValue = "")
            .lines().takeWhile { it != "    }" }.joinToString(separator = " ")
        org.junit.Assert.assertTrue("the worker is told", unbind.contains("TYPE_ACCESSIBILITY_OFF"))
        org.junit.Assert.assertTrue("with the moment it happened", unbind.contains("eventAtMs = unboundAt"))
        // U2b: the poll is silenced inside the worker, before its POST — not in a scope onDestroy cancels.
        val worker = java.io.File(System.getProperty("user.dir") ?: ".").let { wd ->
            listOf(
                java.io.File(wd, "src/main/java/com/familyshield/agent/security/TamperAlertWorker.kt"),
                java.io.File(wd, "app/src/main/java/com/familyshield/agent/security/TamperAlertWorker.kt"),
            ).firstOrNull { it.isFile }?.readText() ?: error("worker source not found")
        }
        org.junit.Assert.assertTrue("the worker records the off state", worker.contains("recordAccessibilityEnabled(false)"))
        org.junit.Assert.assertTrue("through the same throttle key the poll reads", worker.contains("AccessibilityOffPolicy.TYPE"))
    }

    /** One alert per unbind, and two unbinds are two alerts. */
    @Test
    fun `the unbind alert is deduped by its own moment`() {
        val first = TamperAlertDedupe.accessibilityOffKey("dev", 1_000L)
        val retry = TamperAlertDedupe.accessibilityOffKey("dev", 1_000L)
        val second = TamperAlertDedupe.accessibilityOffKey("dev", 61_000L)
        org.junit.Assert.assertEquals("a WorkManager retry is a no-op", first, retry)
        org.junit.Assert.assertNotEquals("a second unbind is a new alert", first, second)
    }

    /**
     * R2's wiring: the latch is delegated to the pure rule, and it is read where the screen is classified.
     *
     * The **decision** is driven by `AccessibilityOffPolicyTest` now — this row only proves the service asks it,
     * which is all a source row can honestly prove after the extraction.
     */
    @Test
    fun `the grant latch is delegated and read`() {
        val source = java.io.File(System.getProperty("user.dir") ?: ".").let { wd ->
            listOf(
                java.io.File(wd, "src/main/java/com/familyshield/agent/services/AccessibilityMonitorService.kt"),
                java.io.File(wd, "app/src/main/java/com/familyshield/agent/services/AccessibilityMonitorService.kt"),
            ).firstOrNull { it.isFile }?.readText() ?: error("service source not found")
        }
        org.junit.Assert.assertTrue(
            "the pure rule owns the latch",
            source.contains("AccessibilityOffPolicy.nextLatch("),
        )
        org.junit.Assert.assertTrue(
            "and the value is read where the screen is classified",
            source.contains("ourLocationActive = permissionWindowLocationActive ?: locationGrantedNow()"),
        )
        org.junit.Assert.assertTrue(
            "and cleared when one of our own windows opens",
            source.contains("permissionWindowLocationActive = null"),
        )
    }

    /** U1 (Antigravity's re-review): the unbind type gets its own work name, keyed by when it happened. */
    @Test
    fun `the unbind work name carries its moment`() {
        val first = TamperAlertWorker.uniqueWorkName(TamperAlertWorker.TYPE_ACCESSIBILITY_OFF, 1_000L)
        val second = TamperAlertWorker.uniqueWorkName(TamperAlertWorker.TYPE_ACCESSIBILITY_OFF, 61_000L)
        org.junit.Assert.assertTrue("the moment is in the name", first.contains("1000"))
        org.junit.Assert.assertNotEquals("two unbinds do not collapse onto one name", first, second)
        // #792: this used to grep `TamperAlertWorker.kt` for the inline `if` that picked the instant. That row could
        // not fail when the selection moved (it did, into `workNameInstant`), and it could not fail when the choice
        // was wrong either — only when the text changed. It now drives the seam that makes the choice, for both
        // event-keyed types, and the lockout's own row is in `TamperAlertLockoutBodyTest`.
        org.junit.Assert.assertEquals(
            "the unbind is named by its own moment, not by the guard window",
            61_000L,
            TamperAlertWorker.workNameInstant(TamperAlertWorker.TYPE_ACCESSIBILITY_OFF, 61_000L, 0L),
        )
        org.junit.Assert.assertEquals(
            "a guard window still names its aggregate, not the event instant",
            5_000L,
            TamperAlertWorker.workNameInstant(TamperAlertWorker.TYPE_GUARD_TRIGGERED, 61_000L, 5_000L),
        )
    }
}
