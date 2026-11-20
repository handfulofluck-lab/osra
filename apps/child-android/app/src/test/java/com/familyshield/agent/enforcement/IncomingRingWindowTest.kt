package com.familyshield.agent.enforcement

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import com.familyshield.agent.security.ShadePolicy
import java.io.File

/**
 * #828 / #851 / osra-security#33 / osra-security#43: incoming cellular call exemption for the lock shade guard.
 *
 * Mutants stated beside each check per AGENTS.md §3:
 * - M1: return `mode == RINGTONE` from [IncomingRingWindow.isRinging] -> silent/DND cellular ring loses Answer.
 * - M2: make [IncomingRingWindow.fromTrustedSource] `pkg == defaultDialer` only -> One UI `com.samsung.android.incallui`
 *   silent ring loses Answer.
 * - M3: ignore `blockedRingActive` in [IncomingRingWindow.isRinging] -> a blocked or locked non-essential
 *   app's `MODE_RINGTONE` suppresses shade collapse during lock/pause (osra-security#33).
 * - M4: ignore `hasHangUp` in [IncomingRingWindow.next] -> answered call keeps silent-ring window open.
 * - M5 (Ahmed B1, osra-security#43): leave `ringUntilMs` intact when the trusted call notification is removed
 *   (`onNotificationRemoved`) -> declined or missed call on silent/DND keeps `isRinging()` true for 45 s and
 *   suppresses shade collapse over an active lock.
 */
class IncomingRingWindowTest {

    @Before
    fun resetSharedWindow() {
        IncomingRingWindow.resetForTest()
    }

    @Test
    fun `a silent or DND ring sets a bounded window from the call notification`() {
        val until = IncomingRingWindow.next(
            isCall = true,
            hasDecline = true,
            hasHangUp = false,
            mode = CallAudioMode.NORMAL,
            nowMs = 10_000,
            fromDefaultDialer = true,
        )
        assertEquals(10_000 + IncomingRingWindow.WINDOW_MS, until)
        assertTrue(IncomingRingWindow.isRinging(CallAudioMode.NORMAL, 11_000, until!!))
        assertFalse(IncomingRingWindow.isRinging(CallAudioMode.NORMAL, 10_000 + IncomingRingWindow.WINDOW_MS + 1, until))
    }

    @Test
    fun `a platform in-call UI package may set the window, One UI's included`() {
        // Mutant M2: restrict fromTrustedSource to defaultDialer only -> Samsung incallui fails here.
        val samsung = IncomingRingWindow.fromTrustedSource(
            pkg = "com.samsung.android.incallui",
            defaultDialer = "com.samsung.android.dialer",
            platformInCallUi = EssentialPackages.inCallUi,
        )
        assertTrue(samsung)
        assertEquals(
            20_000 + IncomingRingWindow.WINDOW_MS,
            IncomingRingWindow.next(
                isCall = true,
                hasDecline = true,
                hasHangUp = false,
                mode = CallAudioMode.NORMAL,
                nowMs = 20_000,
                fromDefaultDialer = samsung,
            ),
        )
        assertTrue(IncomingRingWindow.fromTrustedSource("com.android.incallui", "com.android.dialer", EssentialPackages.inCallUi))
        assertTrue(IncomingRingWindow.fromTrustedSource("com.google.android.dialer", "com.google.android.dialer", EssentialPackages.inCallUi))
    }

    @Test
    fun `an ordinary app posting a call notification cannot set the window`() {
        val trusted = IncomingRingWindow.fromTrustedSource(
            pkg = "com.example.chat",
            defaultDialer = "com.samsung.android.dialer",
            platformInCallUi = EssentialPackages.inCallUi,
        )
        assertFalse(trusted)
        assertNull(
            IncomingRingWindow.next(
                isCall = true,
                hasDecline = true,
                hasHangUp = false,
                mode = CallAudioMode.NORMAL,
                nowMs = 30_000,
                fromDefaultDialer = trusted,
            ),
        )
    }

    @Test
    fun `an audible cellular ring is exempt while no blocked ring is active`() {
        assertNull(IncomingRingWindow.next(isCall = true, hasDecline = true, hasHangUp = false, mode = CallAudioMode.RINGTONE, nowMs = 1_000, fromDefaultDialer = true))
        assertTrue(IncomingRingWindow.isRinging(CallAudioMode.RINGTONE, 1_000, 0L, blockedRingActive = false))
    }

    @Test
    fun `a blocked or locked non-essential app ring never opens the shade exemption even in MODE_RINGTONE`() {
        // Mutant M3 (osra-security#33): return true on CallAudioMode.RINGTONE without checking blockedRingActive ->
        // fails both assertions below, and fails the CallBlockPolicy integration flow.
        assertFalse(IncomingRingWindow.isRinging(CallAudioMode.RINGTONE, 1_000, 0L, blockedRingActive = true))
        assertFalse(IncomingRingWindow.isRinging(CallAudioMode.NORMAL, 1_000, 20_000L, blockedRingActive = true))

        val policy = CallBlockPolicy()
        val lockedNonEssential = "com.google.android.apps.tachyon"
        val isBlockedUnderLock: (String) -> Boolean = { true } // LockState.isActive == true
        val isEssential: (String) -> Boolean = { it == "com.samsung.android.incallui" }

        // Unlocked/heads-up ring under lock: declined + covered -> blockedRingActive == true -> isRinging == false.
        val actions = policy.onNotification(
            CallNotice(
                lockedNonEssential,
                CallParcel(isCall = true, hasDecline = true, hasHangUp = true, ongoing = true, postedAt = 100L),
            ),
            isBlockedUnderLock,
            isEssential,
            nowMs = 500L,
        )
        assertEquals(listOf(CallAction.Decline(lockedNonEssential), CallAction.ShowRingCover), actions)
        policy.onAudioMode(CallAudioMode.RINGTONE, isBlockedUnderLock, nowMs = 600L)
        assertTrue(policy.blockedRingActive)
        assertFalse(IncomingRingWindow.isRinging(CallAudioMode.RINGTONE, 600L, 0L, blockedRingActive = policy.blockedRingActive))

        // If a real platform incoming call arrives during that window, CallBlockPolicy drops the cover and exempts it.
        policy.onNotification(CallNotice("com.samsung.android.incallui", parcel = null), isBlockedUnderLock, isEssential, nowMs = 700L)
        assertFalse(policy.blockedRingActive)
        assertTrue(IncomingRingWindow.isRinging(CallAudioMode.RINGTONE, 700L, 0L, blockedRingActive = policy.blockedRingActive))
    }

    @Test
    fun `CallEnforcer wires blockedRingActive into IncomingRingWindow isRinging`() {
        val source = source("apps/child-android/app/src/main/java/com/familyshield/agent/services/CallEnforcer.kt")
        assertTrue(source.contains("IncomingRingWindow.isSharedRinging(currentMode(), now(), blockedRingActive = policy.blockedRingActive)"))
    }

    @Test
    fun `removing the call notification ends the silent or DND ring window immediately so the shade collapses`() {
        // Mutant M5 (Ahmed B1, osra-security#43): leave ringUntilMs open until the 45 s timer expires ->
        // isSharedRinging stays true after removal and ShadePolicy.shouldCollapse returns false.
        var closedCallbacks = 0
        IncomingRingWindow.setOnWindowClosed { closedCallbacks++ }

        IncomingRingWindow.recordPostedNotice(
            pkg = "com.samsung.android.incallui",
            key = "0|com.samsung.android.incallui|42|null|10051",
            isCall = true,
            isMissedCall = false,
            hasDecline = true,
            hasHangUp = false,
            mode = CallAudioMode.NORMAL,
            nowMs = 10_000L,
            fromTrustedSource = true,
        )
        assertTrue(IncomingRingWindow.isSharedRinging(CallAudioMode.NORMAL, nowMs = 12_000L))
        assertFalse(
            ShadePolicy.shouldCollapse(
                locked = true,
                packageName = ShadePolicy.SHADE_PACKAGE,
                className = "com.android.systemui.shade.NotificationShadeWindowView",
                apiLevel = 33,
                callRinging = IncomingRingWindow.isSharedRinging(CallAudioMode.NORMAL, nowMs = 12_000L),
            ),
        )

        // Unrelated app or non-call removal from another package never closes an active cellular ring.
        IncomingRingWindow.recordRemovedNotice(
            pkg = "com.whatsapp",
            key = "0|com.whatsapp|99|null|10200",
            isCall = true,
            nowMs = 12_500L,
        )
        assertTrue(IncomingRingWindow.isSharedRinging(CallAudioMode.NORMAL, nowMs = 12_500L))
        assertEquals(0, closedCallbacks)

        // Declined / missed / caller-cancelled: trusted call notice removed well before 45 s.
        IncomingRingWindow.recordRemovedNotice(
            pkg = "com.samsung.android.incallui",
            key = "0|com.samsung.android.incallui|42|null|10051",
            isCall = true,
            nowMs = 13_000L,
        )
        assertFalse(IncomingRingWindow.isSharedRinging(CallAudioMode.NORMAL, nowMs = 13_000L))
        assertEquals(1, closedCallbacks)
        assertTrue(
            ShadePolicy.shouldCollapse(
                locked = true,
                packageName = ShadePolicy.SHADE_PACKAGE,
                className = "com.android.systemui.shade.NotificationShadeWindowView",
                apiLevel = 33,
                callRinging = IncomingRingWindow.isSharedRinging(CallAudioMode.NORMAL, nowMs = 13_000L),
            ),
        )
    }

    @Test
    fun `removing the call notification by package also closes a window opened via AccessibilityEvent before key attachment`() {
        var closedCallbacks = 0
        IncomingRingWindow.setOnWindowClosed { closedCallbacks++ }

        // AccessibilityEvent arrives without a StatusBarNotification key.
        IncomingRingWindow.recordPostedNotice(
            pkg = "com.samsung.android.incallui",
            key = null,
            isCall = true,
            isMissedCall = false,
            hasDecline = true,
            hasHangUp = false,
            mode = CallAudioMode.NORMAL,
            nowMs = 20_000L,
            fromTrustedSource = true,
        )
        assertTrue(IncomingRingWindow.isSharedRinging(CallAudioMode.NORMAL, nowMs = 21_000L))

        // NotificationListenerService removes the call notice for that package.
        IncomingRingWindow.recordRemovedNotice(
            pkg = "com.samsung.android.incallui",
            key = "0|com.samsung.android.incallui|77|null|10051",
            isCall = true,
            nowMs = 22_000L,
        )
        assertFalse(IncomingRingWindow.isSharedRinging(CallAudioMode.NORMAL, nowMs = 22_000L))
        assertEquals(1, closedCallbacks)
    }

    @Test
    fun `a missed call notice also closes the silent ring window on the accessibility path`() {
        IncomingRingWindow.recordPostedNotice(
            pkg = "com.google.android.dialer",
            key = null,
            isCall = true,
            isMissedCall = false,
            hasDecline = true,
            hasHangUp = false,
            mode = CallAudioMode.NORMAL,
            nowMs = 30_000L,
            fromTrustedSource = true,
        )
        assertTrue(IncomingRingWindow.isSharedRinging(CallAudioMode.NORMAL, nowMs = 31_000L))

        IncomingRingWindow.recordPostedNotice(
            pkg = "com.google.android.dialer",
            key = null,
            isCall = false,
            isMissedCall = true,
            hasDecline = false,
            hasHangUp = false,
            mode = CallAudioMode.NORMAL,
            nowMs = 32_000L,
            fromTrustedSource = true,
        )
        assertFalse(IncomingRingWindow.isSharedRinging(CallAudioMode.NORMAL, nowMs = 32_000L))
    }

    @Test
    fun `NotificationCaptureService and AccessibilityMonitorService wire call-notice removal into IncomingRingWindow`() {
        val listenerSource = source("apps/child-android/app/src/full/java/com/familyshield/agent/services/NotificationCaptureService.kt")
        assertTrue(listenerSource.contains("IncomingRingWindow.recordRemovedNotice("))
        assertTrue(listenerSource.contains("IncomingRingWindow.recordPostedNotice("))

        val a11ySource = source("apps/child-android/app/src/main/java/com/familyshield/agent/services/AccessibilityMonitorService.kt")
        assertTrue(a11ySource.contains("IncomingRingWindow.setOnWindowClosed"))
    }

    @Test
    fun `answering clears the window, so the shade locks again during the call`() {
        // Mutant M4: ignore hasHangUp -> fails here.
        assertEquals(0L, IncomingRingWindow.next(isCall = true, hasDecline = false, hasHangUp = true, mode = CallAudioMode.IN_CALL, nowMs = 20_000, fromDefaultDialer = true))
        assertFalse(IncomingRingWindow.isRinging(CallAudioMode.IN_CALL, 20_001, 0L))
    }

    @Test
    fun `a placed call is never exempt, even with a stale window`() {
        val until = 60_000L
        assertFalse(IncomingRingWindow.isRinging(CallAudioMode.IN_CALL, 30_000, until))
        assertFalse(IncomingRingWindow.isRinging(CallAudioMode.IN_COMMUNICATION, 30_000, until))
    }

    @Test
    fun `an ongoing notice from another app cannot close or open the window`() {
        assertNull(IncomingRingWindow.next(isCall = true, hasDecline = false, hasHangUp = true, mode = CallAudioMode.IN_CALL, nowMs = 2_000, fromDefaultDialer = false))
    }

    @Test
    fun `a notification that is not a call changes nothing`() {
        assertNull(IncomingRingWindow.next(isCall = false, hasDecline = true, hasHangUp = false, mode = CallAudioMode.NORMAL, nowMs = 1_000, fromDefaultDialer = true))
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
