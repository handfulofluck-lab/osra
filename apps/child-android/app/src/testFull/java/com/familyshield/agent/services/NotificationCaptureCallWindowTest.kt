package com.familyshield.agent.services

import android.app.Notification
import com.familyshield.agent.enforcement.CallAudioMode
import com.familyshield.agent.enforcement.IncomingRingWindow
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test

/**
 * Full-flavor production entry-point tests for [NotificationCaptureService.trackCallWindowNotice]
 * (`osra-security#43`, `osra-security#49`).
 */
class NotificationCaptureCallWindowTest {

    @Before
    fun resetWindow() {
        IncomingRingWindow.resetForTest()
    }

    @Test
    fun `trackCallWindowNotice keeps one fixed deadline across updates, ignores outdated key removals, and collapses on owner removal`() {
        var collapseCount = 0
        AccessibilityMonitorService.bindRingWindowCallbacks(
            scheduler = object : IncomingRingWindow.Scheduler {
                override fun schedule(delayMs: Long, action: () -> Unit) = Unit
                override fun cancel() = Unit
            },
            onClosed = {
                AccessibilityMonitorService.collapseShadeOnRingClosed(
                    isRunning = true,
                    locked = true,
                    lastSystemUiClass = "com.android.systemui.shade.NotificationShadeWindowView",
                    apiLevel = 34,
                    callRinging = IncomingRingWindow.isSharedRinging(CallAudioMode.NORMAL, 18_000L),
                    onCollapse = { collapseCount++ },
                )
            },
        )

        val ownPkg = "com.osratech.child.full"
        val incallUi = "com.samsung.android.incallui"
        val dialer = "com.samsung.android.dialer"
        val activeKey = "0|com.samsung.android.incallui|102|null|10051"
        val staleKey = "0|com.samsung.android.incallui|101|null|10051"

        // Initial silent/DND incoming call post at t = 10_000.
        NotificationCaptureService.trackCallWindowNotice(
            ownPackage = ownPkg,
            pkg = incallUi,
            key = activeKey,
            category = Notification.CATEGORY_CALL,
            hasDecline = true,
            hasHangUp = false,
            removed = false,
            defaultDialer = dialer,
            mode = CallAudioMode.NORMAL,
            nowMs = 10_000L,
        )
        val expectedDeadline = 10_000L + IncomingRingWindow.WINDOW_MS
        assertEquals(expectedDeadline, IncomingRingWindow.currentStateForTest().ringUntilMs)

        // Duplicate update of the same call at t = 15_000 does not push out the deadline.
        NotificationCaptureService.trackCallWindowNotice(
            ownPackage = ownPkg,
            pkg = incallUi,
            key = activeKey,
            category = Notification.CATEGORY_CALL,
            hasDecline = true,
            hasHangUp = false,
            removed = false,
            defaultDialer = dialer,
            mode = CallAudioMode.NORMAL,
            nowMs = 15_000L,
        )
        assertEquals(expectedDeadline, IncomingRingWindow.currentStateForTest().ringUntilMs)

        // Outdated removal of an earlier call key (101) leaves active call (102) open.
        NotificationCaptureService.trackCallWindowNotice(
            ownPackage = ownPkg,
            pkg = incallUi,
            key = staleKey,
            category = Notification.CATEGORY_CALL,
            hasDecline = false,
            hasHangUp = false,
            removed = true,
            defaultDialer = dialer,
            mode = CallAudioMode.NORMAL,
            nowMs = 16_000L,
        )
        assertTrue(IncomingRingWindow.isSharedRinging(CallAudioMode.NORMAL, 16_000L))
        assertEquals(0, collapseCount)

        // Removal of active owner key (102) closes immediately and runs shade collapse.
        NotificationCaptureService.trackCallWindowNotice(
            ownPackage = ownPkg,
            pkg = incallUi,
            key = activeKey,
            category = Notification.CATEGORY_CALL,
            hasDecline = false,
            hasHangUp = false,
            removed = true,
            defaultDialer = dialer,
            mode = CallAudioMode.NORMAL,
            nowMs = 18_000L,
        )
        assertFalse(IncomingRingWindow.isSharedRinging(CallAudioMode.NORMAL, 18_000L))
        assertEquals(1, collapseCount)
    }
}
