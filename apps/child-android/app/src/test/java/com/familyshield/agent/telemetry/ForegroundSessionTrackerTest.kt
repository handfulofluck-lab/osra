package com.familyshield.agent.telemetry

import com.familyshield.agent.data.db.UsageEventEntity
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

/**
 * Behavioral regression tests for `UsageReporter.recordForeground` / `ForegroundSessionTracker`
 * across System UI and app transitions (PR #958 review: leaving `activeForegroundPkg = SYSTEM_UI_PACKAGE`).
 */
class ForegroundSessionTrackerTest {

    private val systemUi = "com.android.systemui"
    private val ownPkg = "com.osratech.child.full"
    private val youtube = "com.google.android.youtube"
    private val chrome = "com.android.chrome"

    @Test
    fun `transitioning from child app to System UI clears activeForegroundPkg so attribution never targets systemui`() {
        val tracker = ForegroundSessionTracker()

        assertEquals(youtube, tracker.onForeground(youtube, 1_000L, systemUi))
        assertEquals(
            youtube,
            continuationPackage(
                events = listOf(UsageEventEntity(packageId = youtube, timestamp = 1_000L)),
                ownPackage = ownPkg,
                activeForegroundPkg = tracker.activeForegroundPkg,
                screenInteractive = true,
                consentPaused = false,
            ),
        )

        // Transition to System UI (keyguard / shade / AOD): must clear activeForegroundPkg immediately.
        assertNull(tracker.onForeground(systemUi, 2_000L, systemUi))
        assertNull(tracker.activeForegroundPkg)
        assertNull(
            continuationPackage(
                events = listOf(
                    UsageEventEntity(packageId = youtube, timestamp = 1_000L),
                    UsageEventEntity(packageId = ownPkg, timestamp = 2_000L),
                ),
                ownPackage = ownPkg,
                activeForegroundPkg = tracker.activeForegroundPkg,
                screenInteractive = true,
                consentPaused = false,
            ),
        )

        // Opening another child app resumes foreground attribution; own window & screen-off clear again.
        assertEquals(chrome, tracker.onForeground(chrome, 3_000L, systemUi))
        assertEquals(chrome, tracker.activeForegroundPkg)
        tracker.onOwnWindow()
        assertNull(tracker.activeForegroundPkg)

        tracker.onForeground(youtube, 4_000L, systemUi)
        tracker.onScreenOff()
        assertNull(tracker.activeForegroundPkg)
    }
}
