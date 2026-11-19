package com.familyshield.agent.security

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * #813 review (Claude): the worker's two decisions as pure functions.
 *
 * They were inline before, and the rows that covered them only read the source — deleting the `TYPE_ACCESSIBILITY_OFF`
 * branch or the uncapped retry failed no test. These do.
 *
 * Mutants: drop the unbind branch from [TamperAlertWorker.dedupeKeyFor] → [the unbind key is the moment of the
 * unbind]; use `eventTimestamp()` for it → same row; drop the unbind exemption from [TamperAlertWorker.shouldRetry]
 * → [the unbind alert never gives up]; make it always true → [an ordinary alert still gives up after five tries].
 */
class TamperAlertWorkerPolicyTest {

    private fun key(
        type: String,
        eventAtMs: Long = 5_000L,
        window: GuardAttemptWindow.State? = null,
        attemptCount: Int = 0,
    ) =
        TamperAlertWorker.dedupeKeyFor(
            type = type,
            deviceId = "dev-1",
            guardWindow = window,
            app = "com.whatsapp",
            layout = "split",
            eventAtMs = eventAtMs,
            adminRemovedAtMs = 9_999L,
            attemptCount = attemptCount,
        )

    @Test
    fun `the unbind key is the moment of the unbind`() {
        val first = key(TamperAlertWorker.TYPE_ACCESSIBILITY_OFF, eventAtMs = 5_000L)
        val second = key(TamperAlertWorker.TYPE_ACCESSIBILITY_OFF, eventAtMs = 65_000L)
        assertTrue("the device is in it", first!!.contains("dev-1"))
        assertTrue("the type is in it", first.contains(TamperAlertWorker.TYPE_ACCESSIBILITY_OFF))
        assertEquals("two unbinds are two keys", false, first == second)
    }

    @Test
    fun `the guard window keys on its start, not on the attempt`() {
        val window = GuardAttemptWindow.State(windowStartMs = 1_000L, count = 3)
        assertEquals(key(TamperAlertWorker.TYPE_GUARD_TRIGGERED, window = window), key(TamperAlertWorker.TYPE_GUARD_TRIGGERED, window = window))
        assertNull("no window, no key", key(TamperAlertWorker.TYPE_GUARD_TRIGGERED, window = null))
    }

    @Test
    fun `an admin removal keys on when it happened`() {
        assertTrue(key(TamperAlertWorker.TYPE_ADMIN_REMOVED)!!.contains("9999"))
    }

    @Test
    fun `a type with no dedupe has no key`() {
        assertNull(key(TamperAlertWorker.TYPE_VPN_REVOKED))
    }

    @Test
    fun `the unbind alert never gives up`() {
        assertTrue(TamperAlertWorker.shouldRetry(TamperAlertWorker.TYPE_ACCESSIBILITY_OFF, runAttemptCount = 0))
        assertTrue("not even after twenty tries", TamperAlertWorker.shouldRetry(TamperAlertWorker.TYPE_ACCESSIBILITY_OFF, 20))
    }

    @Test
    fun `an ordinary alert still gives up after five tries`() {
        assertTrue(TamperAlertWorker.shouldRetry(TamperAlertWorker.TYPE_ADMIN_REMOVED, 4))
        assertFalse(TamperAlertWorker.shouldRetry(TamperAlertWorker.TYPE_ADMIN_REMOVED, 5))
    }

    /**
     * osra-security#29 review (Antigravity): both reporters of one switch-off stamp the same moment, so the server
     * dedupes on one key instead of paging twice — one alert with a key and one poll without it was two pages.
     */
    @Test
    fun `the poll and the unbind alert agree on the key for one switch-off`() {
        val at = 1_700_000_000_000L
        val fromUnbind = TamperAlertWorker.dedupeKeyFor(
            type = TamperAlertWorker.TYPE_ACCESSIBILITY_OFF,
            deviceId = "dev-9",
            guardWindow = null,
            app = "",
            layout = "",
            eventAtMs = at,
            adminRemovedAtMs = 0L,
        )
        // The poll reads the moment the service stamped, and builds the key with the same function.
        val fromPoll = TamperAlertDedupe.accessibilityOffKey("dev-9", at)
        assertEquals("one switch-off, one key, whichever reporter asks", fromPoll, fromUnbind)
    }

    /**
     * Antigravity's Finding 1 on #792 (`S1` survived): the `TYPE_PIN_LOCKOUT` branch of `dedupeKeyFor` had no row, so
     * **deleting it passed every suite** — and that branch is the regression my own claim 3 named. A row that cannot
     * fail on the line it describes is worse than none, so this one drives the key it produces.
     *
     * Mutant: delete `TYPE_PIN_LOCKOUT -> TamperAlertDedupe.pinLockoutKey(...)` in `TamperAlertWorker.kt` → this row
     * goes red (the key becomes null).
     */
    @Test
    fun `a lockout keys on its own failure instant and its count`() {
        val at = 5_000L
        val first = key(TamperAlertWorker.TYPE_PIN_LOCKOUT, eventAtMs = at, attemptCount = 5)
        assertTrue("the device is in it", first != null && first.contains("dev-1"))
        assertTrue("the type is in it", first!!.contains(TamperAlertWorker.TYPE_PIN_LOCKOUT))
        assertTrue("the failure instant is in it", first.contains("$at"))
        assertTrue("the count is in it, so attempt N+1 is a new key", first.endsWith("|5"))
        assertEquals(
            "a WorkManager retry of attempt 5 is the same key, or it pages twice",
            first,
            key(TamperAlertWorker.TYPE_PIN_LOCKOUT, eventAtMs = at, attemptCount = 5),
        )
        assertTrue(
            "the next lockout is a different key",
            first != key(TamperAlertWorker.TYPE_PIN_LOCKOUT, eventAtMs = at + 60_000L, attemptCount = 5),
        )
        assertTrue(
            "the next attempt inside one lockout is a different key",
            first != key(TamperAlertWorker.TYPE_PIN_LOCKOUT, eventAtMs = at, attemptCount = 6),
        )
    }
}
