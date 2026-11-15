package com.familyshield.agent.commands

import java.io.File
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * #734 (Flip4, 13 Nov 20:24Z): Home hid the ring screen while the alarm kept ringing, and nothing on the
 * phone could stop it. While [Ringer.isRinging] the service brings the screen back; these rows pin when.
 *
 * Three of them exist because the first version was wrong in ways a verifier found (Claude's V1–V3 on #802):
 * a wall clock in the debounce (#802 V1), a debounced change dropped instead of deferred (#802 V2), and the
 * whole own package exempted rather than just the ring screen and its PIN gate (osra-security#31).
 *
 * Mutants, one per row: drop the `isRinging` guard → [no ring, nothing is restored]; exempt the package instead
 * of the class → [our own launcher activity is not the ring screen]; return IGNORE where it should DEFER →
 * [a Home press inside the debounce is deferred, not dropped]; drop the debounce → [two changes inside the
 * debounce restore once and defer once].
 */
class RingReentryPolicyTest {

    private val ours = "com.familyshield.agent"
    private val launcher = "com.android.launcher3"
    private val childApp = "com.whatsapp"
    private val ringScreen = "$ours.commands.RingActivity"
    private val pinGate = "$ours.security.TamperGuardActivity"
    private val ownLauncher = "$ours.ui.LauncherActivity"

    private fun decide(
        ringing: Boolean = true,
        foreground: String? = launcher,
        cls: String? = null,
        now: Long = 1_000_000L,
        last: Long = 0L,
    ) = RingReentryPolicy.decide(ringing, foreground, cls, ours, now, last)

    @Test
    fun `no ring, nothing is restored`() {
        assertEquals(RingReentryPolicy.Reentry.IGNORE, decide(ringing = false))
        assertEquals(RingReentryPolicy.Reentry.IGNORE, decide(ringing = false, foreground = childApp))
    }

    @Test
    fun `Home is covered - the launcher does not end a ring`() {
        assertEquals(RingReentryPolicy.Reentry.RESTORE, decide(foreground = launcher))
    }

    @Test
    fun `any app the child opens is covered`() {
        assertEquals(RingReentryPolicy.Reentry.RESTORE, decide(foreground = childApp))
    }

    /**
     * osra-security#31: the first version exempted every window of our own package, and the child app has a
     * launcher activity — so Home, then the OSRA child app from the launcher, escaped the ring entirely.
     */
    @Test
    fun `our own launcher activity is not the ring screen`() {
        assertEquals(
            RingReentryPolicy.Reentry.RESTORE,
            decide(foreground = ours, cls = ownLauncher),
        )
        assertFalse(RingReentryPolicy.isRingScreen(ours, ownLauncher, ours))
    }

    @Test
    fun `the ring screen and its PIN gate are not covered`() {
        assertEquals(RingReentryPolicy.Reentry.IGNORE, decide(foreground = ours, cls = ringScreen))
        assertEquals(RingReentryPolicy.Reentry.IGNORE, decide(foreground = ours, cls = pinGate))
        assertTrue(RingReentryPolicy.isRingScreen(ours, ringScreen, ours))
        assertTrue(RingReentryPolicy.isRingScreen(ours, pinGate, ours))
        // The task variant the guard service launches (#484) is the same screen.
        assertTrue(RingReentryPolicy.isRingScreen(ours, "$ours.security.TamperGuardTaskActivity", ours))
    }

    /** An unnamed window is not proof the ring screen is gone; and a foreign class cannot be our screen. */
    @Test
    fun `an unnamed window decides nothing, and a foreign class is never our ring screen`() {
        assertEquals(RingReentryPolicy.Reentry.IGNORE, decide(foreground = null))
        assertFalse(RingReentryPolicy.isRingScreen(ours, "com.other.RingActivity", ours))
        assertFalse(RingReentryPolicy.isRingScreen(childApp, ringScreen, ours))
    }

    @Test
    fun `two changes inside the debounce restore once and defer once`() {
        assertEquals("the first change restores the screen", RingReentryPolicy.Reentry.RESTORE, decide(now = 1_000_000L, last = 0L))
        assertEquals(
            "400 ms later the same launch is still running, so this one is deferred",
            RingReentryPolicy.Reentry.DEFER,
            decide(now = 1_000_400L, last = 1_000_000L),
        )
        assertEquals(
            "at the debounce it restores again",
            RingReentryPolicy.Reentry.RESTORE,
            decide(now = 1_001_500L, last = 1_000_000L),
        )
    }

    /** #802 V1: the decision reads the monotonic clock only, so a wall-clock jump cannot change it. */
    @Test
    fun `the policy never reads a wall clock`() {
        val source = sourceFile("src/main/java/com/familyshield/agent/commands/RingReentryPolicy.kt")
            // No comment stripping: the policy file names no clock API in its prose either.
        assertFalse(
            "no System.currentTimeMillis in the rule: a changed wall clock must not delay the screen (#802 V1)",
            source.contains("System.currentTimeMillis"),
        )
        assertTrue("the time parameter is the monotonic reading", source.contains("nowElapsedMs"))
    }

    // ---- wiring: the decisions above are useless unless the service asks them and the screen can come back.

    private val service by lazy { sourceFile("src/main/java/com/familyshield/agent/services/AccessibilityMonitorService.kt") }
    private val ring by lazy { sourceFile("src/main/java/com/familyshield/agent/commands/RingActivity.kt") }

    @Test
    fun `the service asks the policy on every window change, on the monotonic clock`() {
        val restore = service.substringAfter("private fun restoreRingScreen(", missingDelimiterValue = "")
            .substringBefore("\n    }\n", missingDelimiterValue = "")
        assertTrue("the policy decides", restore.contains("RingReentryPolicy.decide("))
        assertTrue("the ring's own state is the input", restore.contains("Ringer.isRinging"))
        assertTrue("the window's class, not its package alone, is what it exempts", restore.contains("foregroundClass = classOfForeground"))
        assertTrue("the monotonic clock (#802 V1)", restore.contains("SystemClock.elapsedRealtime()"))
        assertTrue("only a state change, not a content change", restore.contains("TYPE_WINDOW_STATE_CHANGED"))
        assertTrue("the ring screen is brought to the front", service.contains("RingActivity::class.java"))
        assertTrue("in its own task, reordered", service.contains("FLAG_ACTIVITY_REORDER_TO_FRONT"))
        assertTrue("a deferred change is scheduled, not dropped (#802 V2)", service.contains("scheduleRingRecheck()"))
        assertTrue("and the re-check is cancelled when the service goes", service.contains("ringRecheckHandler.removeCallbacks"))
    }

    @Test
    fun `the ring screen still has exactly one way out`() {
        assertTrue("Back is swallowed", ring.contains("KeyEvent.KEYCODE_BACK"))
        assertTrue("the volume keys are swallowed", ring.contains("KeyEvent.KEYCODE_VOLUME_UP"))
        assertTrue("the exit is the parent PIN", ring.contains("TamperGuardActivity::class.java"))
        assertTrue("dismissal by the parent's command", ring.contains("EXTRA_DISMISS"))
    }

    private fun sourceFile(relative: String): String {
        val working = File(System.getProperty("user.dir") ?: ".").absoluteFile
        return listOf(File(working, relative), File(working, "app/$relative"))
            .firstOrNull { it.isFile }
            ?.readText()
            ?: error("could not find $relative below ${working.path}")
    }
}
