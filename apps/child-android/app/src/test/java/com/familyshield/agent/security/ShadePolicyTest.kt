package com.familyshield.agent.security

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File

/**
 * #828: with a lock or pause on, the shade must not be usable. The classification is pure so the four
 * "do nothing" cases are rows, not comments: no lock, another package, an old API, and a window whose
 * class the service cannot name.
 */
class ShadePolicyTest {

    @Test
    fun `a locked child opening the shade is collapsed`() {
        assertTrue(ShadePolicy.shouldCollapse(true, "com.android.systemui", "com.android.systemui.shade.NotificationShadeWindowView", 34))
        assertTrue(ShadePolicy.shouldCollapse(true, "com.android.systemui", "com.android.systemui.statusbar.phone.StatusBarWindowView", 33))
    }

    @Test
    fun `an unnamed systemui window is still collapsed, a named other one is not`() {
        // Kimi's review: a system window with a null class on some OEM builds must not switch the guard
        // off silently. Named systemui windows that are not the shade stay excluded.
        assertTrue(ShadePolicy.shouldCollapse(true, "com.android.systemui", null, 34))
        assertFalse(ShadePolicy.shouldCollapse(true, "com.android.systemui", "com.android.systemui.volume.VolumeDialog", 34))
    }

    @Test
    fun `the measured Android 14 event collapses: systemui reports FrameLayout`() {
        // Antigravity, live API 34: top-edge swipe and `cmd statusbar expand-settings` both report
        // class=android.widget.FrameLayout while the shade opens. The old allowlist could never match it.
        assertTrue(ShadePolicy.shouldCollapse(true, "com.android.systemui", "android.widget.FrameLayout", 34))
    }

    @Test
    fun `the measured non-shade dialogs are excluded by name`() {
        assertFalse(ShadePolicy.shouldCollapse(true, "com.android.systemui", "com.android.systemui.globalactions.GlobalActionsDialogLite\$ActionsDialogLite", 34))
        assertFalse(ShadePolicy.shouldCollapse(true, "com.android.systemui", "com.android.systemui.volume.VolumeDialogImpl\$CustomDialog", 34))
    }

    @Test
    fun `without a lock the shade is left alone`() {
        assertFalse(ShadePolicy.shouldCollapse(false, "com.android.systemui", "com.android.systemui.shade.NotificationShadeWindowView", 34))
    }

    @Test
    fun `below API 31 there is no collapse action, so nothing is sent`() {
        assertFalse(ShadePolicy.shouldCollapse(true, "com.android.systemui", "com.android.systemui.shade.NotificationShadeWindowView", 30))
    }

    @Test
    fun `another package is never collapsed`() {
        assertFalse(ShadePolicy.shouldCollapse(true, "com.whatsapp", "com.whatsapp.Conversation", 34))
        // Antigravity: with null and FrameLayout treated as shade-collapsing, the package check is the
        // only thing standing between another app and a collapse; pin it directly.
        assertFalse(ShadePolicy.shouldCollapse(true, "com.whatsapp", null, 34))
        assertFalse(ShadePolicy.shouldCollapse(true, "com.whatsapp", "android.widget.FrameLayout", 34))
        assertFalse(ShadePolicy.shouldCollapse(true, "com.android.systemui", "com.android.systemui.volume.VolumeDialog", 34))
    }

    @Test
    fun `a ringing incoming call is never collapsed, however it is drawn`() {
        // UI/UX Bureau: with the screen on, a call is a heads-up in systemui, not a full-screen intent.
        assertFalse(ShadePolicy.shouldCollapse(true, "com.android.systemui", "com.android.systemui.statusbar.phone.StatusBarWindowView", 34, callRinging = true))
        assertFalse(ShadePolicy.shouldCollapse(true, "com.android.systemui", "com.android.systemui.shade.NotificationShadeWindowView", 34, callRinging = true))
    }

    @Test
    fun `during a placed or answered call the shade is collapsed again`() {
        // Fable's review: the exemption is the ringing phase, not the whole of any call — otherwise a
        // child starts a call and reads the shade from inside it.
        assertTrue(ShadePolicy.shouldCollapse(true, "com.android.systemui", "com.android.systemui.shade.NotificationShadeWindowView", 34, callRinging = false))
    }

    @Test
    fun `the service wires the policy to the lock state, the ringing state and the dismiss action`() {
        val source = source("apps/child-android/app/src/main/java/com/familyshield/agent/services/AccessibilityMonitorService.kt")
        assertTrue(source.contains("ShadePolicy.shouldCollapse("))
        assertTrue(source.contains("locked = LockState.isActive(this)"))
        assertTrue(source.contains("callRinging = calls.isRinging()"))
        assertTrue(source.contains("performGlobalAction(GLOBAL_ACTION_DISMISS_NOTIFICATION_SHADE)"))
    }

    private fun source(relative: String): String {
        var dir: File? = File(System.getProperty("user.dir") ?: ".").absoluteFile
        while (dir != null) {
            val candidate = File(dir, relative)
            if (candidate.isFile) return candidate.readText()
            dir = dir.parentFile
        }
        throw AssertionError("not found from ${System.getProperty("user.dir")}: $relative")
    }
}
