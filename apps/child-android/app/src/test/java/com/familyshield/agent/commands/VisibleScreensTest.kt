package com.familyshield.agent.commands

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Issue #241: `LockActivity.isShowing` was one boolean for every instance. A start-before-stop
 * interleaving cleared it while a new screen was up, so a later unlock acked `not_showing` and left
 * that screen in place. Claude found no live path (commands are 60 s apart and the resolver converges
 * same-poll cases), so this is a latent race — pinned here because the JVM cannot start the Activity.
 */
class VisibleScreensTest {

    @Test
    fun `a single instance shows while started and not after it stops`() {
        val screens = VisibleScreens()

        assertFalse(screens.isShowing)
        screens.started()
        assertTrue(screens.isShowing)
        screens.stopped()
        assertFalse(screens.isShowing)
    }

    @Test
    fun `a new instance starting before the old one stops keeps the screen visible`() {
        // The interleaving the old boolean got wrong: start(new) then stop(old).
        val screens = VisibleScreens()
        screens.started() // the visible lock screen
        screens.started() // a new instance replaces it
        screens.stopped() // the old one's onStop arrives late

        assertTrue("a visible screen must not be reported as gone", screens.isShowing)
        assertEquals(1, screens.startedCount)

        screens.stopped()
        assertFalse(screens.isShowing)
    }

    @Test
    fun `an unmatched stop cannot make the screen invisible or the count negative`() {
        val screens = VisibleScreens()
        screens.stopped()
        assertFalse(screens.isShowing)
        assertEquals(0, screens.startedCount)

        screens.started()
        assertTrue(screens.isShowing)
    }
}
