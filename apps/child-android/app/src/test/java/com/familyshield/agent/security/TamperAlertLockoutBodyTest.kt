package com.familyshield.agent.security

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * #792 (Antigravity B1): a PIN lockout sent as [TamperAlertWorker.TYPE_GUARD_TRIGGERED] had its sentence
 * replaced by the five-attempt aggregation — `GuardAttemptWindow.body` ignores `detail` once the count is
 * above one — so the parent never read how long the gate would stay shut.
 *
 * Mutant: enqueue the lockout as `TYPE_GUARD_TRIGGERED` again → [a lockout keeps its own sentence even at
 * five or more attempts] goes red, and nothing else does.
 */
class TamperAlertLockoutBodyTest {

    private val lockout = "Parent PIN locked for 60 minute(s) after 8 wrong tries."

    @Test
    fun `a lockout keeps its own sentence even at five or more attempts`() {
        val window = GuardAttemptWindow.State(windowStartMs = 1_000L, count = 8, screens = listOf("settings"))
        val body = TamperAlertWorker.bodyFor(TamperAlertWorker.TYPE_PIN_LOCKOUT, lockout, window)
        assertEquals("the lockout sentence must survive", lockout, body)
    }

    /** The bug itself, kept as a row so the reason the type exists is executable rather than remembered. */
    @Test
    fun `the guard type would have replaced the same sentence, which is why the lockout has its own type`() {
        val window = GuardAttemptWindow.State(windowStartMs = 1_000L, count = 8, screens = listOf("settings"))
        val body = TamperAlertWorker.bodyFor(TamperAlertWorker.TYPE_GUARD_TRIGGERED, lockout, window)
        assertTrue("the aggregation replaces the detail", body.contains("8 attempts") || body != lockout)
    }

    @Test
    fun `a lockout is its own alert type with its own title`() {
        assertEquals("parent_pin_locked", TamperAlertWorker.TYPE_PIN_LOCKOUT)
        assertTrue(
            "the type must not share the guard's constant",
            TamperAlertWorker.TYPE_PIN_LOCKOUT != TamperAlertWorker.TYPE_GUARD_TRIGGERED,
        )
    }

    @Test
    fun `one lockout is one work name, and the next lockout is another`() {
        val first = TamperAlertWorker.uniqueWorkName(TamperAlertWorker.TYPE_PIN_LOCKOUT, 1_000L)
        val second = TamperAlertWorker.uniqueWorkName(TamperAlertWorker.TYPE_PIN_LOCKOUT, 61_000L)
        assertTrue("two lockouts must not cancel each other's retry", first != second)
    }
}
