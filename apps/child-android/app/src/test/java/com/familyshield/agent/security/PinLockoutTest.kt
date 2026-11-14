package com.familyshield.agent.security

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * osra-security#24: the wrong-PIN count survives the screen, and a lockout grows.
 *
 * The count lived in a field on `TamperGuardActivity`, so every reopen of a guarded screen began again at
 * zero — five tries per round, no delay, and a 4-digit PIN falls in hours. These rows pin the rule the
 * activity now follows; the activity itself cannot run in a JVM test, which is why every decision is here.
 */
class PinLockoutTest {

    private val t0 = 1_700_000_000_000L
    private fun after(ms: Long) = t0 + ms

    @Test
    fun `nothing locks before the fifth failure`() {
        var state = PinLockout.CLEARED
        repeat(4) { state = PinLockout.recordFailure(state, after(it * 1_000L)) }
        assertEquals(4, state.failures)
        assertFalse(PinLockout.isLocked(state, after(10_000L)))
        assertEquals(0L, PinLockout.remainingMs(state, after(10_000L)))
    }

    @Test
    fun `the fifth failure closes the gate for a minute, and the right PIN is refused inside it`() {
        var state = PinLockout.CLEARED
        repeat(5) { state = PinLockout.recordFailure(state, t0) }
        assertEquals(PinLockout.WINDOWS_MS[0], PinLockout.lockWindowMs(state.failures))
        assertTrue(PinLockout.isLocked(state, after(30_000L)))
        // The gate refuses every PIN, so this is the check the activity makes *before* verifying.
        assertTrue("the right PIN must be refused while the gate is closed", PinLockout.isLocked(state, after(59_999L)))
        assertFalse(PinLockout.isLocked(state, after(60_000L)))
    }

    /** AG02: "the attempt counter survives restarts; back-off grows". */
    @Test
    fun `the window grows 1 min, 5 min, 15 min, then holds at an hour`() {
        assertEquals(60_000L, PinLockout.lockWindowMs(5))
        assertEquals(5 * 60_000L, PinLockout.lockWindowMs(6))
        assertEquals(15 * 60_000L, PinLockout.lockWindowMs(7))
        assertEquals(60 * 60_000L, PinLockout.lockWindowMs(8))
        assertEquals(60 * 60_000L, PinLockout.lockWindowMs(9))
        assertEquals(60 * 60_000L, PinLockout.lockWindowMs(50))
    }

    @Test
    fun `waiting out one window does not reset the count, so the next lockout is longer`() {
        var state = PinLockout.CLEARED
        repeat(5) { state = PinLockout.recordFailure(state, t0) }
        assertFalse(PinLockout.isLocked(state, after(61_000L)))
        // A sixth failure an hour later still counts as the sixth, not the first.
        val again = PinLockout.recordFailure(state, after(3_600_000L))
        assertEquals(6, again.failures)
        assertEquals(5 * 60_000L, PinLockout.lockWindowMs(again.failures))
    }

    /** Moving the phone's clock back must not hand the gate open. */
    @Test
    fun `a clock before the last failure is inside the window, not outside it`() {
        var state = PinLockout.CLEARED
        repeat(5) { state = PinLockout.recordFailure(state, t0) }
        assertTrue(PinLockout.isLocked(state, t0 - 10 * 60_000L))
        assertEquals(PinLockout.WINDOWS_MS[0], PinLockout.remainingMs(state, t0 - 10 * 60_000L))
    }

    @Test
    fun `one alert per lockout, and a new lockout is a new alert`() {
        var state = PinLockout.CLEARED
        repeat(4) { state = PinLockout.recordFailure(state, t0) }
        assertFalse("four failures are not a lockout yet", PinLockout.shouldAlert(state))
        state = PinLockout.recordFailure(state, t0)
        assertTrue("the fifth opens the gate's first lockout", PinLockout.shouldAlert(state))
        state = PinLockout.markedAlerted(state)
        assertFalse("not told again for the same lockout", PinLockout.shouldAlert(state))
        state = PinLockout.recordFailure(state, t0 + 61_000L)
        assertTrue("a further failure is a new lockout, and the parent hears about that one", PinLockout.shouldAlert(state))
    }

    @Test
    fun `the notice says how long, and reads as one line`() {
        assertEquals("Too many tries. Try again in 1 minute, or ask your parent.", PinLockout.lockoutNotice(1L))
        assertEquals("Too many tries. Try again in 1 minute, or ask your parent.", PinLockout.lockoutNotice(59_999L))
        assertEquals("Too many tries. Try again in 5 minutes, or ask your parent.", PinLockout.lockoutNotice(5 * 60_000L))
        assertEquals("Too many tries. Try again in 60 minutes, or ask your parent.", PinLockout.lockoutNotice(60 * 60_000L))
    }

    /**
     * The survival row. Two [PinAttemptStore] instances over the same storage are two activity instances —
     * which is what a reopen of the guarded screen is. Mutant: keep the count in a field on the activity and
     * this row cannot be written at all, which is the point of the store existing.
     */
    @Test
    fun `the count survives a new activity instance`() {
        val backing = HashMap<String, String>()
        val storage = object : PinAttemptStorage {
            override fun get(key: String): String? = backing[key]
            override fun put(key: String, value: String?) {
                if (value == null) backing.remove(key) else backing[key] = value
            }
        }

        val firstOpen = PinAttemptStore(storage)
        repeat(5) { firstOpen.write(PinLockout.recordFailure(firstOpen.read(), t0)) }

        // A brand-new store on the same storage: this is the screen being reopened.
        val secondOpen = PinAttemptStore(storage)
        val state = secondOpen.read()
        assertEquals(5, state.failures)
        assertTrue("reopening the screen must not hand back a fresh set of tries", PinLockout.isLocked(state, after(1_000L)))
    }

    @Test
    fun `a correct pin clears the count, and only a correct pin does`() {
        val backing = HashMap<String, String>()
        val storage = object : PinAttemptStorage {
            override fun get(key: String): String? = backing[key]
            override fun put(key: String, value: String?) {
                if (value == null) backing.remove(key) else backing[key] = value
            }
        }
        val store = PinAttemptStore(storage)
        repeat(5) { store.write(PinLockout.recordFailure(store.read(), t0)) }
        assertEquals(5, store.read().failures)

        store.clear()
        assertEquals(PinLockout.CLEARED, store.read())
        assertFalse(PinLockout.isLocked(store.read(), after(1_000L)))
    }
}
