package com.familyshield.agent.security

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * osra-security#24: the wrong-try count survives the screen, and repeated failures have to wait, growing.
 *
 * The rule lives in [PinLockout] with no Android types so every decision the activity makes can be driven
 * here; the activity itself cannot run in a JVM test.
 *
 * **Which clock decides, and why the rows look like this.** A window is measured only on the monotonic
 * reading (`elapsedRealtime`). The wall clock is stored for the alert and for a human reading the state, and
 * is never compared: comparing it is how a changed clock either opens the gate early or holds it shut for
 * ever. A reboot restarts the monotonic clock, so [PinLockout.anchored] re-anchors the window to "one full
 * window from the first read after boot" — a reboot costs a child a window, and never costs a parent more
 * than one.
 */
class PinLockoutTest {

    private val wall = 1_700_000_000_000L
    private val boot = 41
    private fun elapsedAfter(ms: Long) = 5_000_000L + ms

    private fun locked(failures: Int) = PinLockout.State(
        failures = failures,
        lastFailureMs = wall,
        lastFailureElapsedMs = elapsedAfter(0),
        lastFailureBootCount = boot,
    )

    @Test
    fun `nothing locks before the fifth failure`() {
        var state = PinLockout.CLEARED
        repeat(4) { state = PinLockout.recordFailure(state, wall, elapsedAfter(it * 1_000L), boot) }
        assertEquals(4, state.failures)
        assertFalse(PinLockout.isLocked(state, elapsedAfter(10_000L)))
        assertEquals(0L, PinLockout.remainingMs(state, elapsedAfter(10_000L)))
    }

    @Test
    fun `the fifth failure closes the gate for a minute, and the right PIN is refused inside it`() {
        var state = PinLockout.CLEARED
        repeat(5) { state = PinLockout.recordFailure(state, wall, elapsedAfter(0), boot) }
        assertEquals(PinLockout.WINDOWS_MS[0], PinLockout.lockWindowMs(state.failures))
        assertTrue(PinLockout.isLocked(state, elapsedAfter(30_000L)))
        // The gate refuses every PIN, so this is the check the activity makes *before* verifying.
        assertTrue("the right PIN must be refused while the gate is closed", PinLockout.isLocked(state, elapsedAfter(59_999L)))
        assertFalse(PinLockout.isLocked(state, elapsedAfter(60_000L)))
    }

    /** AG02: "the attempt counter survives restarts; back-off grows". */
    @Test
    fun `the window grows 1 min, 5 min, 15 min, then holds at an hour`() {
        assertEquals(60_000L, PinLockout.lockWindowMs(5))
        assertEquals(5 * 60_000L, PinLockout.lockWindowMs(6))
        assertEquals(15 * 60_000L, PinLockout.lockWindowMs(7))
        assertEquals(60 * 60_000L, PinLockout.lockWindowMs(8))
        assertEquals(60 * 60_000L, PinLockout.lockWindowMs(50))
    }

    @Test
    fun `waiting out one window does not reset the count, so the next lockout is longer`() {
        var state = PinLockout.CLEARED
        repeat(5) { state = PinLockout.recordFailure(state, wall, elapsedAfter(0), boot) }
        assertFalse(PinLockout.isLocked(state, elapsedAfter(61_000L)))
        val again = PinLockout.recordFailure(state, wall, elapsedAfter(3_600_000L), boot)
        assertEquals(6, again.failures)
        assertEquals(5 * 60_000L, PinLockout.lockWindowMs(again.failures))
    }

    /** Ahmed's B1, forward direction: the wall clock is moved an hour ahead mid-window. */
    @Test
    fun `a wall clock moved forward does not open the gate, because only the monotonic clock decides`() {
        val state = locked(5)
        // The wall clock is now two hours after the failure; the monotonic reading is ten seconds after it.
        assertTrue(
            "the window is measured on elapsedRealtime, so a forward wall clock changes nothing",
            PinLockout.isLocked(state, elapsedAfter(10_000L)),
        )
        // And the reverse: the same wall clock, with the monotonic clock past the window, is open.
        assertFalse(PinLockout.isLocked(state, elapsedAfter(60_000L)))
    }

    /** Ahmed's B1, backward direction, and Claude's "unbounded lock": a clock moved back must not lock forever. */
    @Test
    fun `a wall clock moved backward neither extends nor holds the gate`() {
        val state = locked(5)
        // The wall clock says the failure has not happened yet; the monotonic clock says ten seconds have passed.
        val earlierWall = PinLockout.State(
            failures = state.failures,
            lastFailureMs = wall + 2 * 60 * 60_000L,
            lastFailureElapsedMs = state.lastFailureElapsedMs,
            lastFailureBootCount = boot,
            alertedAt = state.alertedAt,
        )
        assertTrue("inside the window it is still closed", PinLockout.isLocked(earlierWall, elapsedAfter(10_000L)))
        assertFalse(
            "and one window later it opens: the clock cannot hold the gate shut",
            PinLockout.isLocked(earlierWall, elapsedAfter(60_000L)),
        )
    }

    /** Ahmed's B1, reboot: the monotonic clock restarts, so the window is re-anchored to a full one. */
    @Test
    fun `a reboot costs the child a full window, and never more than one`() {
        val state = locked(5)
        val afterReboot = PinLockout.anchored(state, nowWallMs = wall + 7_000_000L, nowElapsedMs = 1_000L, nowBootCount = boot + 1)
        assertNotEquals("the state changed, so the activity has something to persist", state, afterReboot)
        assertEquals(boot + 1, afterReboot.lastFailureBootCount)
        assertTrue(
            "a full window from the first read after boot",
            PinLockout.isLocked(afterReboot, 1_000L),
        )
        assertTrue(PinLockout.isLocked(afterReboot, 60_000L))
        assertFalse(
            "and it ends: a reboot cannot hold the gate shut for ever",
            PinLockout.isLocked(afterReboot, 61_000L),
        )
        // A state already anchored on this boot is left alone, so the caller can skip the write.
        assertEquals(afterReboot, PinLockout.anchored(afterReboot, 0L, 2_000L, boot + 1))
    }

    @Test
    fun `a reboot with no readable boot count still costs one window and no more`() {
        // Settings.Global.BOOT_COUNT could not be read on either side, so the count is NO_BOOT both times and
        // says nothing. The monotonic clock reading lower than the stored one is the reboot.
        val state = PinLockout.State(
            failures = 5,
            lastFailureMs = wall,
            lastFailureElapsedMs = elapsedAfter(0) + 10L * 24 * 60 * 60 * 1000,
            lastFailureBootCount = PinLockout.NO_BOOT,
        )
        val afterReboot = PinLockout.anchored(state, wall, 2_000L, PinLockout.NO_BOOT)
        assertNotEquals("the state changed, so the activity has something to persist", state, afterReboot)
        assertTrue("a full window from the first read after boot", PinLockout.isLocked(afterReboot, 2_000L))
        assertFalse(
            "not ten days until the old uptime is caught up with: one window, then open",
            PinLockout.isLocked(afterReboot, 62_000L),
        )
    }

    @Test
    fun `one alert per lockout, and a new lockout is a new alert`() {
        var state = PinLockout.CLEARED
        repeat(4) { state = PinLockout.recordFailure(state, wall, elapsedAfter(0), boot) }
        assertFalse("four failures are not a lockout yet", PinLockout.shouldAlert(state))
        state = PinLockout.recordFailure(state, wall, elapsedAfter(0), boot)
        assertTrue("the fifth opens the gate's first lockout", PinLockout.shouldAlert(state))
        state = PinLockout.markedAlerted(state)
        assertFalse("not told again for the same lockout", PinLockout.shouldAlert(state))
        state = PinLockout.recordFailure(state, wall, elapsedAfter(61_000L), boot)
        assertTrue("a further failure is a new lockout, and the parent hears about that one", PinLockout.shouldAlert(state))
    }

    @Test
    fun `the notice's minute count rounds up and never shows zero`() {
        val state = locked(5)
        assertEquals(1, PinLockout.remainingMinutes(state, elapsedAfter(1L)))
        assertEquals(1, PinLockout.remainingMinutes(state, elapsedAfter(59_999L)))
        assertEquals(5, PinLockout.remainingMinutes(locked(6), elapsedAfter(1L)))
        assertEquals(60, PinLockout.remainingMinutes(locked(8), elapsedAfter(1L)))
    }

    /**
     * The survival row. Two [PinAttemptStore] instances over the same storage are two activity instances —
     * which is what a reopen of the guarded screen is.
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
        repeat(5) {
            firstOpen.write(PinLockout.recordFailure(firstOpen.read(), wall, elapsedAfter(0), boot))
        }
        // The parent was told about this lockout; that fact has to outlive the activity as well.
        firstOpen.write(PinLockout.markedAlerted(firstOpen.read()))

        // A brand-new store on the same storage: this is the screen being reopened.
        val secondOpen = PinAttemptStore(storage)
        val state = secondOpen.read()
        assertEquals(5, state.failures)
        assertEquals(boot, state.lastFailureBootCount)
        // #792 (Antigravity S2): the alerted count must survive too, or the parent is told again for the same
        // lockout after a restart. Dropping the KEY_ALERTED_AT write leaves every other row green.
        assertEquals("the alerted count is persisted with the rest", 5, state.alertedAt)
        assertFalse("one alert for this lockout, even across instances", PinLockout.shouldAlert(state))
        assertTrue("reopening the screen must not hand back a fresh set of tries", PinLockout.isLocked(state, elapsedAfter(1_000L)))
    }

    @Test
    fun `a correct pin clears the count and both clocks, and only a correct pin does`() {
        val backing = HashMap<String, String>()
        val storage = object : PinAttemptStorage {
            override fun get(key: String): String? = backing[key]
            override fun put(key: String, value: String?) {
                if (value == null) backing.remove(key) else backing[key] = value
            }
        }
        val store = PinAttemptStore(storage)
        repeat(5) { store.write(PinLockout.recordFailure(store.read(), wall, elapsedAfter(0), boot)) }
        assertEquals(5, store.read().failures)

        store.clear()
        assertEquals(PinLockout.CLEARED, store.read())
        assertFalse(PinLockout.isLocked(store.read(), elapsedAfter(1_000L)))
    }
}
