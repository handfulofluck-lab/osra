package com.familyshield.agent.security

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotEquals
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

    /**
     * #792 (Antigravity B1), the row the one above was not: `uniqueWorkName` was already right, but `enqueue`
     * passed `windowStartMs`, and `TamperGuardActivity` passes `windowStartMs = 0L` for a lockout — so every real
     * lockout took the static name and a second lockout cancelled the first one's pending retry, while the row
     * above stayed green. This row starts from the arguments the activity actually passes.
     *
     * Mutant: read `windowStartMs` for this type again in `workNameInstant` → this row goes red on the static name.
     */
    @Test
    fun `the lockout enqueue path names the work item after its own failure instant`() {
        val eventAtMs = 1_700_000_000_000L
        val instant = TamperAlertWorker.workNameInstant(
            TamperAlertWorker.TYPE_PIN_LOCKOUT, eventAtMs, windowStartMs = 0L,
        )
        assertEquals("a lockout is named by its failure instant", eventAtMs, instant)

        val name = TamperAlertWorker.uniqueWorkName(TamperAlertWorker.TYPE_PIN_LOCKOUT, instant)
        assertNotEquals("the static name is what cancelled the previous retry", "tamper_alert_parent_pin_locked", name)
        assertTrue("the instant is in the name so two lockouts differ: $name", name.endsWith(eventAtMs.toString()))

        val next = TamperAlertWorker.uniqueWorkName(
            TamperAlertWorker.TYPE_PIN_LOCKOUT,
            TamperAlertWorker.workNameInstant(TamperAlertWorker.TYPE_PIN_LOCKOUT, eventAtMs + 60_000L, 0L),
        )
        assertTrue("the next lockout must not replace the previous one's work", name != next)
    }
}
