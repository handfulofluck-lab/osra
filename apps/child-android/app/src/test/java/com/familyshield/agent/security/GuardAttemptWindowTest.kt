package com.familyshield.agent.security

import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Issue #227: repeated attempts to open the admin-removal screen are one alert per window, carrying
 * the number of attempts. Five attempts 10 s apart used to be five critical pages; the parent now
 * sees one row whose count says five.
 *
 * The window is keyed on the persisted start time and the attempt count only. It is deliberately
 * not keyed on the guard screen becoming visible again: the child reruns the guard every time they
 * retry, so a visibility-keyed window would reset on every attempt and page every time.
 */
class GuardAttemptWindowTest {

    private val t0 = 1_700_000_000_000L

    @Test
    fun `five attempts inside five minutes share one alert and count to five`() {
        var state: GuardAttemptWindow.State? = null
        val windowStarts = mutableSetOf<Long>()

        repeat(5) { i ->
            val attempt = GuardAttemptWindow.record(state, t0 + i * 10_000L)
            state = attempt.state
            windowStarts += attempt.state.windowStartMs
        }

        // One window start means one server dedupe key, hence one alert row.
        assertEquals(1, windowStarts.size)
        assertEquals(t0, windowStarts.single())
        assertEquals(5, state!!.count)
    }

    @Test
    fun `an attempt after the window closes opens a new alert at count one`() {
        val first = GuardAttemptWindow.record(null, t0)
        val lastInside = GuardAttemptWindow.record(first.state, t0 + GuardAttemptWindow.WINDOW_MS - 1)
        val after = GuardAttemptWindow.record(lastInside.state, t0 + GuardAttemptWindow.WINDOW_MS + 1)

        assertEquals(2, lastInside.state.count)
        assertEquals(t0 + GuardAttemptWindow.WINDOW_MS + 1, after.state.windowStartMs)
        assertEquals(1, after.state.count)
        assertTrue(after.opensWindow)
    }

    @Test
    fun `an attempt exactly at the boundary belongs to the new window`() {
        val first = GuardAttemptWindow.record(null, t0)
        val atBoundary = GuardAttemptWindow.record(first.state, t0 + GuardAttemptWindow.WINDOW_MS)

        assertEquals(t0 + GuardAttemptWindow.WINDOW_MS, atBoundary.state.windowStartMs)
        assertEquals(1, atBoundary.state.count)
        assertTrue(atBoundary.opensWindow)
    }

    @Test
    fun `the first attempt pages immediately at count one`() {
        val first = GuardAttemptWindow.record(null, t0)

        assertTrue(first.opensWindow)
        assertEquals(1, first.state.count)
        assertEquals(t0, first.state.windowStartMs)
    }

    /**
     * The count is persisted before the POST, and a key is recorded only after the POST succeeds.
     * Attempt 2 fails offline; attempt 3 must carry 3, not 2 and not 1 — the lost attempt is still
     * counted, and the parent sees the true number when the connection returns.
     */
    @Test
    fun `a failed POST does not lose the attempt count`() = runBlocking {
        val posted = mutableListOf<Int>()
        val postedKeys = mutableSetOf<String>()
        val dispatcher = TamperAlertDispatcher(
            wasPosted = { it in postedKeys },
            recordPosted = { postedKeys += it },
        )
        var state: GuardAttemptWindow.State? = null

        suspend fun attempt(nowMs: Long, fail: Boolean) {
            val next = GuardAttemptWindow.record(state, nowMs)
            state = next.state
            try {
                dispatcher.dispatch(TamperAlertDedupe.guardPostKey("dev-1", next.state)) {
                    if (fail) throw IllegalStateException("offline")
                    posted += next.state.count
                }
            } catch (_: IllegalStateException) {
                // The worker retries; the local count stays where the window put it.
            }
        }

        attempt(t0, fail = false)
        attempt(t0 + 10_000L, fail = true)
        attempt(t0 + 20_000L, fail = false)

        assertEquals(listOf(1, 3), posted)
        assertEquals(3, state!!.count)
        // All three attempts name the same aggregate row; only the count differs in the retry key.
        assertEquals(
            setOf(TamperAlertDedupe.guardAggregateKey("dev-1", t0)),
            postedKeys.map { it.substringBeforeLast('|') }.toSet(),
        )
    }

    @Test
    fun `a retried POST of the same count is posted once`() = runBlocking {
        val posted = mutableListOf<Int>()
        val postedKeys = mutableSetOf<String>()
        val dispatcher = TamperAlertDispatcher(
            wasPosted = { it in postedKeys },
            recordPosted = { postedKeys += it },
        )
        val attempt = GuardAttemptWindow.record(null, t0)
        val key = TamperAlertDedupe.guardPostKey("dev-1", attempt.state)

        assertTrue(dispatcher.dispatch(key) { posted += attempt.state.count })
        // WorkManager retries the same work after a lost response: the key is already recorded.
        dispatcher.dispatch(key) { posted += attempt.state.count }

        assertEquals(listOf(1), posted)
    }
}
