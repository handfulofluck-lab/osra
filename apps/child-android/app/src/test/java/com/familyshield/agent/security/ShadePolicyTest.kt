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
    fun `without a lock the shade is left alone`() {
        assertFalse(ShadePolicy.shouldCollapse(false, "com.android.systemui", "com.android.systemui.shade.NotificationShadeWindowView", 34))
    }

    @Test
    fun `below API 31 there is no collapse action, so nothing is sent`() {
        assertFalse(ShadePolicy.shouldCollapse(true, "com.android.systemui", "com.android.systemui.shade.NotificationShadeWindowView", 30))
    }

    @Test
    fun `another package or an unnamed class is never collapsed`() {
        assertFalse(ShadePolicy.shouldCollapse(true, "com.whatsapp", "com.whatsapp.Conversation", 34))
        assertFalse(ShadePolicy.shouldCollapse(true, "com.android.systemui", null, 34))
        assertFalse(ShadePolicy.shouldCollapse(true, "com.android.systemui", "com.android.systemui.volume.VolumeDialog", 34))
    }

    @Test
    fun `an incoming call is never collapsed, however the call is drawn`() {
        // UI/UX Bureau: with the screen on, a call is a heads-up in systemui, not a full-screen intent.
        assertFalse(ShadePolicy.shouldCollapse(true, "com.android.systemui", "com.android.systemui.statusbar.phone.StatusBarWindowView", 34, callActive = true))
        assertFalse(ShadePolicy.shouldCollapse(true, "com.android.systemui", "com.android.systemui.shade.NotificationShadeWindowView", 34, callActive = true))
    }

    @Test
    fun `the service wires the policy to the lock state, the call state and the dismiss action`() {
        val source = source("apps/child-android/app/src/main/java/com/familyshield/agent/services/AccessibilityMonitorService.kt")
        assertTrue(source.contains("ShadePolicy.shouldCollapse("))
        assertTrue(source.contains("locked = LockState.isActive(this)"))
        assertTrue(source.contains("callActive = calls.isRingingOrInCall()"))
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
