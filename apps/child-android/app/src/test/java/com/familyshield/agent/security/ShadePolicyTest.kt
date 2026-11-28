package com.familyshield.agent.security

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File

/**
 * #828 / osra-security#43 / osra-security#33: while a lock or pause is active, the notification shade
 * must collapse so notification content and inline replies cannot be used over the lock screen.
 *
 * Mutants stated beside each check per AGENTS.md §3:
 * - M1: return false from [ShadePolicy.shouldCollapse] when `className == "android.widget.FrameLayout"`
 *   or `null` -> Android 14 / One UI shade swipe stays open.
 * - M2: omit `!callRinging` in [ShadePolicy.shouldCollapse] or [ShadePolicy.shouldRecheck] -> an
 *   incoming cellular call's heads-up Answer is collapsed while locked with screen on.
 * - M3: keep `current` in [ShadePolicy.nextSystemUiClass] when `eventPkg != SHADE_PACKAGE` or when
 *   `eventClass == null` -> closing VolumeDialog or unlocking Keyguard into LockActivity leaves a
 *   dialog class cached and suppresses [ShadePolicy.shouldCollapseOnContentChange].
 * - M4: drop `LockState.isActive(this)` from `CallEnforcer`'s or `MediaEnforcer`'s `isBlocked` wiring ->
 *   non-essential calls/media are allowed during lock/pause (osra-security#33).
 * - M5: drop `if (!TamperScreenPolicy.mayHostProtectionScreen(pkg)) return` -> synchronous binder stall
 *   during shade teardown can ANR the service.
 */
class ShadePolicyTest {

    @Test
    fun `a locked child opening the shade is collapsed`() {
        assertTrue(ShadePolicy.shouldCollapse(true, "com.android.systemui", "com.android.systemui.shade.NotificationShadeWindowView", 34))
        assertTrue(ShadePolicy.shouldCollapse(true, "com.android.systemui", "com.android.systemui.statusbar.phone.StatusBarWindowView", 33))
    }

    @Test
    fun `an unnamed systemui window is still collapsed, a named other one is not`() {
        // Mutant M1: treat null className as non-shade -> fails here.
        assertTrue(ShadePolicy.shouldCollapse(true, "com.android.systemui", null, 34))
        assertFalse(ShadePolicy.shouldCollapse(true, "com.android.systemui", "com.android.systemui.volume.VolumeDialog", 34))
    }

    @Test
    fun `the measured Android 14 event collapses because systemui reports FrameLayout`() {
        // Mutant M1: positive-only allowlist of shade classes -> fails on FrameLayout.
        assertTrue(ShadePolicy.shouldCollapse(true, "com.android.systemui", "android.widget.FrameLayout", 34))
    }

    @Test
    fun `the measured non-shade dialogs are excluded by name`() {
        assertFalse(ShadePolicy.shouldCollapse(true, "com.android.systemui", "com.android.systemui.globalactions.GlobalActionsDialogLite\$ActionsDialogLite", 34))
        assertFalse(ShadePolicy.shouldCollapse(true, "com.android.systemui", "com.android.systemui.volume.VolumeDialogImpl\$CustomDialog", 34))
        assertFalse(ShadePolicy.shouldCollapse(true, "com.android.systemui", "com.android.systemui.biometrics.AuthContainerView", 34))
        assertFalse(ShadePolicy.shouldCollapse(true, "com.android.systemui", "com.android.keyguard.KeyguardHostView", 34))
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
        assertFalse(ShadePolicy.shouldCollapse(true, "com.whatsapp", null, 34))
        assertFalse(ShadePolicy.shouldCollapse(true, "com.whatsapp", "android.widget.FrameLayout", 34))
    }

    @Test
    fun `a ringing incoming call is never collapsed, however it is drawn`() {
        // Mutant M2: ignore callRinging -> fails here.
        assertFalse(ShadePolicy.shouldCollapse(true, "com.android.systemui", "com.android.systemui.statusbar.phone.StatusBarWindowView", 34, callRinging = true))
        assertFalse(ShadePolicy.shouldCollapse(true, "com.android.systemui", "com.android.systemui.shade.NotificationShadeWindowView", 34, callRinging = true))
    }

    @Test
    fun `during a placed or answered call the shade is collapsed again`() {
        assertTrue(ShadePolicy.shouldCollapse(true, "com.android.systemui", "com.android.systemui.shade.NotificationShadeWindowView", 34, callRinging = false))
    }

    @Test
    fun `a content change under systemui re-collapses while locked, and the dialogs stay excluded`() {
        assertTrue(ShadePolicy.shouldCollapseOnContentChange(true, "com.android.systemui", null, 34, false))
        assertTrue(ShadePolicy.shouldCollapseOnContentChange(true, "com.android.systemui", "android.widget.FrameLayout", 34, false))
        assertFalse(ShadePolicy.shouldCollapseOnContentChange(true, "com.android.systemui", "com.android.systemui.volume.VolumeDialogImpl\$CustomDialog", 34, false))
        assertFalse(ShadePolicy.shouldCollapseOnContentChange(true, "com.whatsapp", null, 34, false))
        assertFalse(ShadePolicy.shouldCollapseOnContentChange(true, "com.android.systemui", null, 34, true))
    }

    @Test
    fun `leaving systemui or seeing a null systemui class clears stale dialog state`() {
        // Mutant M3: keep `current` when another window takes focus or when systemui emits null class ->
        // an earlier VolumeDialog or Keyguard class poisons subsequent content-change collapses.
        val afterDialog = ShadePolicy.nextSystemUiClass(
            current = null,
            eventPkg = "com.android.systemui",
            eventClass = "com.android.systemui.volume.VolumeDialogImpl\$CustomDialog",
        )
        assertEquals("com.android.systemui.volume.VolumeDialogImpl\$CustomDialog", afterDialog)

        val afterLockResumes = ShadePolicy.nextSystemUiClass(
            current = afterDialog,
            eventPkg = "com.osratech.child.full",
            eventClass = "com.familyshield.agent.commands.LockActivity",
        )
        assertNull(afterLockResumes)
        assertTrue(ShadePolicy.shouldCollapseOnContentChange(true, "com.android.systemui", afterLockResumes, 34, false))

        val afterUnnamedSystemUi = ShadePolicy.nextSystemUiClass(
            current = afterDialog,
            eventPkg = "com.android.systemui",
            eventClass = null,
        )
        assertNull(afterUnnamedSystemUi)
    }

    @Test
    fun `the re-check sends only while locked and not ringing`() {
        assertTrue(ShadePolicy.shouldRecheck(locked = true, callRinging = false))
        assertFalse(ShadePolicy.shouldRecheck(locked = false, callRinging = false))
        assertFalse(ShadePolicy.shouldRecheck(locked = true, callRinging = true))
    }

    @Test
    fun `the service guards the protection-screen read and schedules all three fixed-deadline pulses`() {
        val source = source("apps/child-android/app/src/main/java/com/familyshield/agent/services/AccessibilityMonitorService.kt")
        // Mutant M5: delete this guard and systemui shade teardown calls rootInActiveWindow synchronously.
        assertTrue(source.contains("if (!TamperScreenPolicy.mayHostProtectionScreen(pkg)) return"))
        assertTrue(source.contains("scheduleShadeRecheck(delayMs = SHADE_RECHECK_MS, slot = ShadePulse.STATE)"))
        assertTrue(source.contains("scheduleShadeRecheck(delayMs = SHADE_LATE_RECHECK_MS, slot = ShadePulse.LATE)"))
        assertTrue(source.contains("scheduleShadeRecheck(delayMs = SHADE_CONTENT_RECHECK_MS, slot = ShadePulse.CONTENT)"))
        assertTrue(source.contains("if (shadePulse(slot) != null) return"))
        assertTrue(source.contains("shadeRecheck?.let { ringRecheckHandler.removeCallbacks(it) }"))
        assertTrue(source.contains("shadeLateRecheck?.let { ringRecheckHandler.removeCallbacks(it) }"))
        assertTrue(source.contains("shadeContentRecheck?.let { ringRecheckHandler.removeCallbacks(it) }"))
        assertTrue(source.contains("ShadePolicy.nextSystemUiClass("))
    }

    @Test
    fun `the service wires shade collapse and non-essential call and media blocking to LockState`() {
        val source = source("apps/child-android/app/src/main/java/com/familyshield/agent/services/AccessibilityMonitorService.kt")
        assertTrue(source.contains("ShadePolicy.shouldCollapse("))
        assertTrue(source.contains("locked = LockState.isActive(this)"))
        assertTrue(source.contains("callRinging = calls.isRinging()"))
        assertTrue(source.contains("performGlobalAction(GLOBAL_ACTION_DISMISS_NOTIFICATION_SHADE)"))
        // Mutant M4 (osra-security#33): omit LockState.isActive(this) from CallEnforcer / MediaEnforcer
        // and non-essential VoIP rings are not declined/covered while locked.
        val callBlock = source.substringAfter("CallEnforcer(").substringBefore("private val rulesChanged")
        assertTrue(callBlock.contains("LockState.isActive(this) || rules.evaluate(it) != RuleRepository.Decision.ALLOW"))
        val mediaBlock = source.substringAfter("MediaEnforcer(").substringBefore("private var loggedStartDecision")
        assertTrue(mediaBlock.contains("LockState.isActive(this) || rules.evaluate(it) != RuleRepository.Decision.ALLOW"))
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
