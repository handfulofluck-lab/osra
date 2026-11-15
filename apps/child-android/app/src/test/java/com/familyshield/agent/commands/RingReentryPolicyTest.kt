package com.familyshield.agent.commands

import java.io.File
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * #734 (Flip4, 13 Nov 20:24Z): Home hid the ring screen while the alarm kept ringing, and nothing on the
 * phone could stop it. While [Ringer.isRinging] the service brings the screen back; these rows pin when.
 *
 * Mutants, one per row: drop the `isRinging` guard → [no ring, no screen to restore]; drop the own-package
 * guard → [never relaunches over our own screen]; drop the debounce → [two window changes inside the debounce
 * launch once]; treat a backwards clock as "long ago" → [a clock moved backwards holds the screen back].
 */
class RingReentryPolicyTest {

    private val ours = "com.familyshield.agent"
    private val launcher = "com.android.launcher3"
    private val childApp = "com.whatsapp"

    @Test
    fun `no ring, no screen to restore`() {
        assertFalse(RingReentryPolicy.shouldRestore(false, launcher, ours, 1_000_000L, 0L))
        assertFalse(RingReentryPolicy.shouldRestore(false, childApp, ours, 1_000_000L, 0L))
    }

    @Test
    fun `Home is covered - the launcher does not end a ring`() {
        assertTrue(RingReentryPolicy.shouldRestore(true, launcher, ours, 1_000_000L, 0L))
    }

    @Test
    fun `any app the child opens is covered`() {
        assertTrue(RingReentryPolicy.shouldRestore(true, childApp, ours, 1_000_000L, 0L))
    }

    /**
     * The ring screen itself, and the PIN gate it opens, are our own package: relaunching over them would put
     * the exit behind a screen that reopens the screen — the one way to make the exit unreachable.
     */
    @Test
    fun `never relaunches over our own screen`() {
        assertFalse(RingReentryPolicy.shouldRestore(true, ours, ours, 1_000_000L, 0L))
    }

    @Test
    fun `two window changes inside the debounce launch once`() {
        val first = RingReentryPolicy.shouldRestore(true, childApp, ours, 1_000_000L, 0L)
        val second = RingReentryPolicy.shouldRestore(true, childApp, ours, 1_000_400L, 1_000_000L)
        val third = RingReentryPolicy.shouldRestore(true, childApp, ours, 1_001_500L, 1_000_000L)
        assertTrue("the first change restores the screen", first)
        assertFalse("400 ms later is the same launch", second)
        assertTrue("at the debounce it launches again", third)
    }

    /** A debounce a moved clock can satisfy for ever would leave the ring unreachable — the bug itself. */
    @Test
    fun `a clock moved backwards holds the screen back rather than wedging it`() {
        assertFalse(RingReentryPolicy.shouldRestore(true, childApp, ours, 999_000L, 1_000_000L))
    }

    @Test
    fun `an unnamed window is not proof the ring screen is gone`() {
        assertFalse(RingReentryPolicy.shouldRestore(true, null, ours, 1_000_000L, 0L))
    }

    // ---- wiring: the decisions above are useless unless the service asks them and the screen can come back.

    private val service by lazy { sourceFile("src/main/java/com/familyshield/agent/services/AccessibilityMonitorService.kt") }
    private val ring by lazy { sourceFile("src/main/java/com/familyshield/agent/commands/RingActivity.kt") }

    @Test
    fun `the service asks the policy on every window change and launches the ring screen`() {
        val restore = service.substringAfter("private fun restoreRingScreen(", missingDelimiterValue = "")
            .substringBefore("\n    }", missingDelimiterValue = "")
        assertTrue("the policy decides", restore.contains("RingReentryPolicy.shouldRestore("))
        assertTrue("the ring's own state is the input", restore.contains("Ringer.isRinging"))
        assertTrue("our own window is what it must not cover", restore.contains("ownPackage = packageName"))
        assertTrue("the debounce is remembered between events", restore.contains("lastRingRestoreMs = now"))
        assertTrue("the ring screen is brought to the front", restore.contains("RingActivity::class.java"))
        assertTrue("in its own task, reordered to the front", restore.contains("FLAG_ACTIVITY_REORDER_TO_FRONT"))
        assertTrue("and only on a state change, not a content change", restore.contains("TYPE_WINDOW_STATE_CHANGED"))
        // It must run whether or not the child's app was already judged: the call site is outside the
        // consent pause and outside the block branch.
        assertTrue("the call site passes the resolved foreground", service.contains("restoreRingScreen(event, foreground)"))
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
