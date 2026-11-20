package com.familyshield.agent.enforcement

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class FilterRecoveryPolicyTest {
    private val allowed = "com.example.essential"
    private val app = "com.example.app"
    private val appBounds = WindowBounds(0, 400, 600, 800)

    @Test fun coversSecondaryPaneWithoutReplacingTheEssentialForeground() {
        val snapshot = WindowSnapshot(allowed, listOf(
            VisibleWindow(allowed, bounds = WindowBounds(0, 0, 600, 400)),
            VisibleWindow(app, bounds = appBounds),
        ))
        val result = FilterRecoveryPolicy.presentation(snapshot, allowed) { it == allowed }
        assertNull(result.blockedForeground)
        assertEquals(setOf(appBounds), result.coveredWindows)
    }

    @Test fun coversPictureInPictureAndShowsRecoveryForTheActiveApp() {
        val snapshot = WindowSnapshot(app, listOf(
            VisibleWindow(app, bounds = WindowBounds(0, 0, 600, 800)),
            VisibleWindow("com.example.video", inPictureInPicture = true, bounds = appBounds),
        ))
        val result = FilterRecoveryPolicy.presentation(snapshot, app) { false }
        assertEquals(app, result.blockedForeground)
        assertEquals(setOf(appBounds), result.coveredWindows)
    }

    @Test fun regularForegroundUsesOnlyTheRecoveryScreen() {
        val snapshot = WindowSnapshot(app, listOf(VisibleWindow(app, bounds = appBounds)))
        val result = FilterRecoveryPolicy.presentation(snapshot, app) { false }
        assertEquals(app, result.blockedForeground)
        assertTrue(result.coveredWindows.isEmpty())
    }
}
