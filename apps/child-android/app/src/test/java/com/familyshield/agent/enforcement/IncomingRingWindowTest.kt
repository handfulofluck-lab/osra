package com.familyshield.agent.enforcement

import com.familyshield.agent.security.ShadePolicy
import com.familyshield.agent.services.AccessibilityMonitorService
import com.familyshield.agent.services.CallEnforcer
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import java.io.File

/**
 * #828 / #851 / osra-security#33 / osra-security#43 / osra-security#48 / osra-security#49:
 * incoming cellular call exemption and bounded window lifecycle across the real production entry points
 * ([CallEnforcer.Coordinator], [AccessibilityMonitorService.bindRingWindowCallbacks],
 * [AccessibilityMonitorService.collapseShadeOnRingClosed], and [IncomingRingWindow]).
 *
 * Mutants stated beside each check per AGENTS.md §3:
 * - M1: return `mode == RINGTONE` from [IncomingRingWindow.isRinging] -> silent/DND cellular ring loses Answer.
 * - M2: make [IncomingRingWindow.fromTrustedSource] `pkg == defaultDialer` only -> One UI `com.samsung.android.incallui`
 *   silent ring loses Answer.
 * - M3 (osra-security#33): ignore `blockedRingActive` in [IncomingRingWindow.isRinging] -> a blocked or locked
 *   non-essential app's `MODE_RINGTONE` suppresses shade collapse during lock/pause.
 * - M4: ignore `hasHangUp` / `IN_CALL` in [IncomingRingWindow.recordPostedNotice] -> answered call keeps silent-ring window open.
 * - M5 (osra-security#43): leave `ringUntilMs` intact when the trusted call notification is removed ->
 *   declined or missed call on silent/DND keeps `isRinging()` true for 45 s.
 * - M6 (osra-security#48): omit essential check in `isBlocked` / `onAudioMode` or infer `blockedRingActive` from
 *   `ringPkg != null` -> permitted platform call under lock loses shade exemption or triggers hang-up / report.
 * - M7 (osra-security#49): push `ringUntilMs` out on duplicate updates of an active call -> unbounded silent-ring window.
 * - M8 (osra-security#49): match removal by package when `ownerKey` is already known -> outdated removal closes a newer call.
 * - M9 (osra-security#49): fail to fire `onWindowClosed` / scheduled expiry when `ringUntilMs` elapses without a listener ->
 *   already-open shade is not collapsed on Play / listener-absent expiry.
 */
class IncomingRingWindowTest {

    private class FakeScheduler : IncomingRingWindow.Scheduler {
        var scheduledDelayMs: Long? = null
        var scheduleCount = 0
        var cancelCount = 0
        var pendingAction: (() -> Unit)? = null

        override fun schedule(delayMs: Long, action: () -> Unit) {
            scheduledDelayMs = delayMs
            scheduleCount++
            pendingAction = action
        }

        override fun cancel() {
            cancelCount++
            pendingAction = null
        }
    }

    @Before
    fun resetSharedWindow() {
        IncomingRingWindow.resetForTest()
    }

    @Test
    fun `CallEnforcer production entry point opens a bounded silent-ring window for default dialer and One UI incallui`() {
        // Mutants M1 & M2: restrict to MODE_RINGTONE or defaultDialer-only -> Samsung incallui silent ring fails here.
        var nowMs = 10_000L
        var audioMode = CallAudioMode.NORMAL
        val dialer = "com.samsung.android.dialer"
        val incallUi = "com.samsung.android.incallui"
        val essential = setOf(dialer, incallUi)
        val enforcer = CallEnforcer.Coordinator(
            ownPackage = "com.osratech.child",
            isBlocked = { pkg ->
                AccessibilityMonitorService.isNonEssentialBlocked(
                    isEssential = pkg in essential,
                    lockedOrRuleBlocked = true,
                )
            },
            isEssential = { it in essential },
            defaultDialerProvider = { dialer },
            modeProvider = { audioMode },
            clock = { nowMs },
        )

        val ringParcel = CallParcel(isCall = true, hasDecline = true, hasHangUp = false, ongoing = true, postedAt = 10_000L)
        assertEquals(emptyList<CallAction>(), enforcer.onNotification(incallUi, ringParcel, nowMs = nowMs))
        nowMs = 11_000L
        assertTrue(enforcer.isRinging(nowMs))

        // Ordinary app posting a call notification never opens the window and is declined + covered under lock.
        IncomingRingWindow.resetForTest()
        val chatActions = enforcer.onNotification("com.example.chat", ringParcel, nowMs = 20_000L)
        assertEquals(listOf(CallAction.Decline("com.example.chat"), CallAction.ShowRingCover), chatActions)
        assertFalse(enforcer.isRinging(20_500L))
    }

    @Test
    fun `osra-security 48 - CallEnforcer under lock preserves permitted platform calls in both orderings`() {
        // Mutant M6: drop essential check on connected-call adoption or blockedRingActive ->
        // either RINGTONE collapses the shade or 10 s into IN_CALL emits ReportCall.
        val dialer = "com.samsung.android.dialer"
        val incallUi = "com.samsung.android.incallui"
        val essential = setOf(dialer, incallUi)
        val ringParcel = CallParcel(isCall = true, hasDecline = true, hasHangUp = false, ongoing = true, postedAt = 1L)
        val connectedParcel = CallParcel(isCall = true, hasDecline = false, hasHangUp = true, ongoing = true, postedAt = 2L)

        // Ordering 1: notice -> MODE_RINGTONE -> MODE_IN_CALL -> 20 s tick.
        var mode1 = CallAudioMode.NORMAL
        var now1 = 1_000L
        val enforcer1 = CallEnforcer.Coordinator(
            ownPackage = "com.osratech.child",
            isBlocked = { pkg -> AccessibilityMonitorService.isNonEssentialBlocked(pkg in essential, lockedOrRuleBlocked = true) },
            isEssential = { it in essential },
            defaultDialerProvider = { dialer },
            modeProvider = { mode1 },
            clock = { now1 },
        )
        assertEquals(emptyList<CallAction>(), enforcer1.onNotification(incallUi, ringParcel, nowMs = now1))
        assertTrue(enforcer1.isRinging(now1))
        mode1 = CallAudioMode.RINGTONE
        now1 = 1_200L
        assertEquals(emptyList<CallAction>(), enforcer1.onAudioMode(mode1, now1))
        assertTrue("audible ring must stay exempt after notice", enforcer1.isRinging(now1))
        mode1 = CallAudioMode.IN_CALL
        now1 = 3_000L
        assertEquals(emptyList<CallAction>(), enforcer1.onAudioMode(mode1, now1))
        assertFalse("connected call closes shade exemption", enforcer1.isRinging(now1))
        now1 = 3_500L
        assertEquals(emptyList<CallAction>(), enforcer1.onNotification(incallUi, connectedParcel, nowMs = now1))
        now1 = 25_000L
        assertEquals(emptyList<CallAction>(), enforcer1.onAudioMode(mode1, now1))

        // Ordering 2: MODE_RINGTONE -> notice -> MODE_IN_CALL -> 20 s tick.
        IncomingRingWindow.resetForTest()
        var mode2 = CallAudioMode.RINGTONE
        var now2 = 5_000L
        val enforcer2 = CallEnforcer.Coordinator(
            ownPackage = "com.osratech.child",
            isBlocked = { pkg -> AccessibilityMonitorService.isNonEssentialBlocked(pkg in essential, lockedOrRuleBlocked = true) },
            isEssential = { it in essential },
            defaultDialerProvider = { dialer },
            modeProvider = { mode2 },
            clock = { now2 },
        )
        assertEquals(emptyList<CallAction>(), enforcer2.onAudioMode(mode2, now2))
        assertTrue(enforcer2.isRinging(now2))
        now2 = 5_300L
        assertEquals(emptyList<CallAction>(), enforcer2.onNotification(dialer, ringParcel, nowMs = now2))
        assertTrue(enforcer2.isRinging(now2))
        mode2 = CallAudioMode.IN_CALL
        now2 = 7_000L
        assertEquals(emptyList<CallAction>(), enforcer2.onAudioMode(mode2, now2))
        assertFalse(enforcer2.isRinging(now2))
        now2 = 7_500L
        assertEquals(emptyList<CallAction>(), enforcer2.onNotification(dialer, connectedParcel, nowMs = now2))
        now2 = 30_000L
        assertEquals(emptyList<CallAction>(), enforcer2.onAudioMode(mode2, now2))
    }

    @Test
    fun `a blocked or locked non-essential app ring never opens the shade exemption even in MODE_RINGTONE`() {
        // Mutant M3 (osra-security#33): return true on CallAudioMode.RINGTONE without checking blockedRingActive.
        assertFalse(IncomingRingWindow.isRinging(CallAudioMode.RINGTONE, 1_000, 0L, blockedRingActive = true))
        assertFalse(IncomingRingWindow.isRinging(CallAudioMode.NORMAL, 1_000, 20_000L, blockedRingActive = true))

        val lockedNonEssential = "com.google.android.apps.tachyon"
        val incallUi = "com.samsung.android.incallui"
        var mode = CallAudioMode.NORMAL
        val enforcer = CallEnforcer.Coordinator(
            ownPackage = "com.osratech.child",
            isBlocked = { it != incallUi },
            isEssential = { it == incallUi },
            defaultDialerProvider = { "com.samsung.android.dialer" },
            modeProvider = { mode },
        )

        val actions = enforcer.onNotification(
            lockedNonEssential,
            CallParcel(isCall = true, hasDecline = true, hasHangUp = true, ongoing = true, postedAt = 100L),
            nowMs = 500L,
        )
        assertEquals(listOf(CallAction.Decline(lockedNonEssential), CallAction.ShowRingCover), actions)
        mode = CallAudioMode.RINGTONE
        enforcer.onAudioMode(mode, 600L)
        assertFalse(enforcer.isRinging(600L))

        // Real platform call arriving during that ring drops the cover and restores the exemption.
        assertEquals(listOf(CallAction.RemoveRingCover), enforcer.onNotification(incallUi, parcel = null, nowMs = 700L))
        assertTrue(enforcer.isRinging(700L))
    }

    @Test
    fun `osra-security 49 - duplicate updates never push out the active call deadline`() {
        // Mutant M7: overwrite ringUntilMs with `nowMs + WINDOW_MS` on every update -> window stays open past 55_000L.
        val scheduler = FakeScheduler()
        var closedCount = 0
        AccessibilityMonitorService.bindRingWindowCallbacks(scheduler = scheduler, onClosed = { closedCount++ })

        IncomingRingWindow.recordPostedNotice(
            pkg = "com.samsung.android.incallui",
            key = "0|com.samsung.android.incallui|42|null|10051",
            isCall = true,
            hasDecline = true,
            hasHangUp = false,
            mode = CallAudioMode.NORMAL,
            nowMs = 10_000L,
            fromTrustedSource = true,
        )
        val initialDeadline = 10_000L + IncomingRingWindow.WINDOW_MS
        assertEquals(initialDeadline, IncomingRingWindow.currentStateForTest().ringUntilMs)
        assertEquals(1, scheduler.scheduleCount)

        // Same key update at 25 s and accessibility-path (null key) update at 40 s must not push out ringUntilMs.
        IncomingRingWindow.recordPostedNotice(
            pkg = "com.samsung.android.incallui",
            key = "0|com.samsung.android.incallui|42|null|10051",
            isCall = true,
            hasDecline = true,
            hasHangUp = false,
            mode = CallAudioMode.NORMAL,
            nowMs = 25_000L,
            fromTrustedSource = true,
        )
        IncomingRingWindow.recordPostedNotice(
            pkg = "com.samsung.android.incallui",
            key = null,
            isCall = true,
            hasDecline = true,
            hasHangUp = false,
            mode = CallAudioMode.NORMAL,
            nowMs = 40_000L,
            fromTrustedSource = true,
        )
        assertEquals(initialDeadline, IncomingRingWindow.currentStateForTest().ringUntilMs)
        assertEquals(1, scheduler.scheduleCount)
        assertTrue(IncomingRingWindow.isSharedRinging(CallAudioMode.NORMAL, initialDeadline - 1L))
        assertFalse(IncomingRingWindow.isSharedRinging(CallAudioMode.NORMAL, initialDeadline))
        assertEquals(1, closedCount)
    }

    @Test
    fun `osra-security 49 - once ownerKey is known, outdated or unkeyed removals cannot close the active call`() {
        // Mutant M8: accept `pkg == ownerPkg && isCall` even when `ownerKey != null` -> outdated removal kills call 43.
        var closedCount = 0
        IncomingRingWindow.setOnWindowClosed { closedCount++ }

        // Accessibility opens first without key, then NotificationListener attaches key 42 without pushing deadline.
        IncomingRingWindow.recordPostedNotice(
            pkg = "com.samsung.android.incallui",
            key = null,
            isCall = true,
            hasDecline = true,
            hasHangUp = false,
            mode = CallAudioMode.NORMAL,
            nowMs = 10_000L,
            fromTrustedSource = true,
        )
        IncomingRingWindow.recordPostedNotice(
            pkg = "com.samsung.android.incallui",
            key = "0|com.samsung.android.incallui|42|null|10051",
            isCall = true,
            hasDecline = true,
            hasHangUp = false,
            mode = CallAudioMode.NORMAL,
            nowMs = 10_050L,
            fromTrustedSource = true,
        )
        assertEquals(10_000L + IncomingRingWindow.WINDOW_MS, IncomingRingWindow.currentStateForTest().ringUntilMs)
        assertEquals("0|com.samsung.android.incallui|42|null|10051", IncomingRingWindow.currentStateForTest().ownerKey)

        // Outdated removal from an earlier call key (41) of the SAME package must be ignored.
        IncomingRingWindow.recordRemovedNotice(
            pkg = "com.samsung.android.incallui",
            key = "0|com.samsung.android.incallui|41|null|10051",
            isCall = true,
            nowMs = 12_000L,
        )
        assertTrue(IncomingRingWindow.isSharedRinging(CallAudioMode.NORMAL, 12_000L))
        assertEquals(0, closedCount)

        // Matching key 42 closes immediately.
        IncomingRingWindow.recordRemovedNotice(
            pkg = "com.samsung.android.incallui",
            key = "0|com.samsung.android.incallui|42|null|10051",
            isCall = true,
            nowMs = 13_000L,
        )
        assertFalse(IncomingRingWindow.isSharedRinging(CallAudioMode.NORMAL, 13_000L))
        assertEquals(1, closedCount)
    }

    @Test
    fun `osra-security 49 - expiry without a notification listener runs the exact close-and-collapse path`() {
        // Mutant M9: omit scheduled expiry or fail to invoke onWindowClosed on expiry ->
        // Play / listener-absent silent ring leaves an already-pulled shade open after 45 s.
        val scheduler = FakeScheduler()
        var nowMs = 10_000L
        var shadeDismissals = 0
        lateinit var enforcer: CallEnforcer.Coordinator

        AccessibilityMonitorService.bindRingWindowCallbacks(
            scheduler = scheduler,
            onClosed = {
                AccessibilityMonitorService.collapseShadeOnRingClosed(
                    isRunning = true,
                    locked = true,
                    lastSystemUiClass = "com.android.systemui.shade.NotificationShadeWindowView",
                    apiLevel = 34,
                    callRinging = enforcer.isRinging(nowMs),
                    onCollapse = { shadeDismissals++ },
                )
            },
        )

        enforcer = CallEnforcer.Coordinator(
            ownPackage = "com.osratech.child",
            isBlocked = { it != "com.google.android.dialer" },
            isEssential = { it == "com.google.android.dialer" },
            defaultDialerProvider = { "com.google.android.dialer" },
            modeProvider = { CallAudioMode.NORMAL },
            clock = { nowMs },
        )

        val ringParcel = CallParcel(isCall = true, hasDecline = true, hasHangUp = false, ongoing = true, postedAt = 10_000L)
        enforcer.onNotification("com.google.android.dialer", ringParcel, nowMs = nowMs)
        assertEquals(IncomingRingWindow.WINDOW_MS, scheduler.scheduledDelayMs)
        assertEquals(1, scheduler.scheduleCount)

        // Duplicate accessibility update at 30 s must neither extend deadline nor re-arm timer.
        nowMs = 30_000L
        enforcer.onNotification("com.google.android.dialer", ringParcel, nowMs = nowMs)
        assertEquals(1, scheduler.scheduleCount)
        assertTrue(enforcer.isRinging(nowMs))
        assertEquals(0, shadeDismissals)

        // At 55_000L (45 s after initial ring), timer fires without any NotificationListenerService removal.
        nowMs = 10_000L + IncomingRingWindow.WINDOW_MS
        IncomingRingWindow.expireIfDue(nowMs)
        assertFalse(enforcer.isRinging(nowMs))
        assertEquals(1, shadeDismissals)
    }

    @Test
    fun `removing an unkeyed accessibility window by package still works when no key was ever attached`() {
        var closedCallbacks = 0
        IncomingRingWindow.setOnWindowClosed { closedCallbacks++ }

        IncomingRingWindow.recordPostedNotice(
            pkg = "com.samsung.android.incallui",
            key = null,
            isCall = true,
            hasDecline = true,
            hasHangUp = false,
            mode = CallAudioMode.NORMAL,
            nowMs = 20_000L,
            fromTrustedSource = true,
        )
        assertTrue(IncomingRingWindow.isSharedRinging(CallAudioMode.NORMAL, nowMs = 21_000L))

        // Non-call removal from the same package must NOT close an unkeyed call window.
        IncomingRingWindow.recordRemovedNotice(
            pkg = "com.samsung.android.incallui",
            key = "0|com.samsung.android.incallui|99|voicemail|10051",
            isCall = false,
            nowMs = 21_500L,
        )
        assertTrue(IncomingRingWindow.isSharedRinging(CallAudioMode.NORMAL, nowMs = 21_500L))
        assertEquals(0, closedCallbacks)

        // Call removal from that package closes it.
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
    fun `missed call and answered hang-up notices close the silent ring window immediately`() {
        // Mutant M4: ignore hasHangUp / isMissedCall -> window stays open.
        var closedCallbacks = 0
        IncomingRingWindow.setOnWindowClosed { closedCallbacks++ }

        IncomingRingWindow.recordPostedNotice(
            pkg = "com.google.android.dialer",
            key = "k1",
            isCall = true,
            hasDecline = true,
            hasHangUp = false,
            mode = CallAudioMode.NORMAL,
            nowMs = 30_000L,
            fromTrustedSource = true,
        )
        assertTrue(IncomingRingWindow.isSharedRinging(CallAudioMode.NORMAL, nowMs = 31_000L))

        IncomingRingWindow.recordPostedNotice(
            pkg = "com.google.android.dialer",
            key = "k1",
            isCall = true,
            hasDecline = false,
            hasHangUp = true,
            mode = CallAudioMode.IN_CALL,
            nowMs = 32_000L,
            fromTrustedSource = true,
        )
        assertFalse(IncomingRingWindow.isSharedRinging(CallAudioMode.IN_CALL, nowMs = 32_000L))
        assertEquals(1, closedCallbacks)
    }

    @Test
    fun `CallEnforcer, NotificationCaptureService and AccessibilityMonitorService wire the production entry points`() {
        val enforcerSource = source("apps/child-android/app/src/main/java/com/familyshield/agent/services/CallEnforcer.kt")
        assertTrue(enforcerSource.contains("IncomingRingWindow.isSharedRinging(modeProvider(), nowMs, blockedRingActive = policy.blockedRingActive)"))
        assertTrue(enforcerSource.contains("policy.onAudioMode(mode, isBlocked, nowMs, isEssential)"))

        val listenerSource = source("apps/child-android/app/src/full/java/com/familyshield/agent/services/NotificationCaptureService.kt")
        assertTrue(listenerSource.contains("trackCallWindowNotice("))
        assertTrue(listenerSource.contains("IncomingRingWindow.recordRemovedNotice("))
        assertTrue(listenerSource.contains("IncomingRingWindow.recordPostedNotice("))

        val a11ySource = source("apps/child-android/app/src/main/java/com/familyshield/agent/services/AccessibilityMonitorService.kt")
        assertTrue(a11ySource.contains("bindRingWindowCallbacks("))
        assertTrue(a11ySource.contains("IncomingRingWindow.unbindCallbacks()"))
        assertTrue(a11ySource.contains("collapseShadeOnRingClosed("))
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
