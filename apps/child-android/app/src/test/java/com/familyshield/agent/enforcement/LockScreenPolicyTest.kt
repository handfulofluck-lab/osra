package com.familyshield.agent.enforcement

import org.junit.Assert.assertEquals
import org.junit.Test

/**
 * Issue #233 review (F1/F2), measured on the Flip4 on 2026-10-20: an unlock that *worked* was acked
 * `failed unlock_screen_unavailable`, and a replayed `MODE_UNLOCK` finished a lock screen 5 ms after
 * a later `lock` raised it.
 *
 * [LockScreenPolicy.resolve] is the rule that makes the second impossible: the intent is a wake-up,
 * [LockState] says what belongs on screen, and every combination of the two is pinned here.
 */
class LockScreenPolicyTest {

    private val storedModes = listOf(
        LockState.MODE_NONE,
        "locked",
        "paused",
        "paused_internet",
    )

    private val intentModes = listOf("locked", "unlock", "dismiss")

    /** The 4 stored × 3 intent table the reviewer asked for, row by row. */
    @Test
    fun `the full stored-mode by intent-mode table`() {
        for (stored in storedModes) {
            for (intent in intentModes) {
                val expected = when {
                    stored == LockState.MODE_NONE && intent == "unlock" -> LockScreenPolicy.Decision.DismissKeyguard
                    stored == LockState.MODE_NONE -> LockScreenPolicy.Decision.Finish
                    else -> LockScreenPolicy.Decision.Show(stored)
                }

                assertEquals(
                    "stored=$stored intent=$intent",
                    expected,
                    LockScreenPolicy.resolve(stored, intent),
                )
            }
        }
    }

    // ---- the rows that matter on their own -----------------------------------------------------

    @Test
    fun `a stored lock beats a replayed unlock intent (F2)`() {
        // The event log: a refused `lock` created an activity record that never started, row 2's
        // MODE_UNLOCK was queued on it, and when the launch became allowed the record started with
        // those intents and finished the new lock screen at +5 ms while the ack said via=overlay.
        assertEquals(
            LockScreenPolicy.Decision.Show("locked"),
            LockScreenPolicy.resolve(storedMode = "locked", intentMode = "unlock"),
        )
        assertEquals(
            LockScreenPolicy.Decision.Show("locked"),
            LockScreenPolicy.resolve(storedMode = "locked", intentMode = "dismiss"),
        )
    }

    @Test
    fun `a stored pause draws paused whatever the intent says`() {
        for (intent in intentModes) {
            assertEquals(
                "intent=$intent",
                LockScreenPolicy.Decision.Show("paused"),
                LockScreenPolicy.resolve("paused", intent),
            )
        }
        assertEquals(
            LockScreenPolicy.Decision.Show("paused_internet"),
            LockScreenPolicy.resolve("paused_internet", "unlock"),
        )
    }

    @Test
    fun `a cleared state finishes, and only an unlock intent also dismisses the keyguard`() {
        assertEquals(
            LockScreenPolicy.Decision.DismissKeyguard,
            LockScreenPolicy.resolve(LockState.MODE_NONE, "unlock"),
        )
        assertEquals(
            "a stale lock intent after an unlock must not draw a lock screen",
            LockScreenPolicy.Decision.Finish,
            LockScreenPolicy.resolve(LockState.MODE_NONE, "locked"),
        )
        assertEquals(
            LockScreenPolicy.Decision.Finish,
            LockScreenPolicy.resolve(LockState.MODE_NONE, "dismiss"),
        )
    }

    @Test
    fun `an unknown or absent stored mode is not a locking mode`() {
        // Drawing a lock for a value we do not recognise would be a false lock; the safe direction
        // for an unknown stored state is to take the overlay down.
        for (stored in listOf(null, "", "  ", "unlocked", "LOCKED")) {
            assertEquals(
                "stored=$stored",
                LockScreenPolicy.Decision.Finish,
                LockScreenPolicy.resolve(stored, "locked"),
            )
        }
        assertEquals(
            "a missing intent extra is the activity's locked default, not an unlock",
            LockScreenPolicy.Decision.Finish,
            LockScreenPolicy.resolve(null, null),
        )
    }
}
