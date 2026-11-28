package com.familyshield.agent.security

import com.familyshield.agent.commands.CommandPollWorker
import com.familyshield.agent.recovery.ServiceRecovery
import com.familyshield.agent.recovery.ServiceRecoveryPolicy
import com.familyshield.agent.recovery.ServiceRevivalPolicy
import com.familyshield.agent.recovery.ServiceRevivalReceiver
import com.familyshield.agent.setup.MiuiAutostartPolicy
import com.familyshield.agent.setup.MiuiAutostartState
import com.familyshield.agent.setup.RecentsExclusionPolicy
import java.io.File
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * osra-security#78: discriminating pure-policy, queued-recovery, and call-site wiring tests for:
 * 1. [AdminDisableRequestPolicy] + immediate/expedited alert delivery on [GuardianAdminReceiver.onDisableRequested],
 * 2. [UnboundTamperPolicy] unrelated-app controls + [ManageSpaceGatePolicy] post-PIN management handoff,
 * 3. Bounded revival window cap/reset + standing non-wakeup watchdog + durable `unlinkPending` gates,
 * 4. [MiuiAutostartPolicy] + Xiaomi `BATTERY` onboarding requirement + Xiaomi-scoped [RecentsExclusionPolicy].
 */
class MiuiGuardAndRevivalSec78Test {

    // -------------------------------------------------------------------------
    // 1. AdminDisableRequestPolicy & ManageSpaceGatePolicy
    // -------------------------------------------------------------------------

    /**
     * Mutant: omit `unlinkPending`, grace, or sanctioned checks, or return ALLOW_WITHOUT_GATE when
     * `canLaunchFromBackground` is true -> either revives/blocks during approved removal or drops
     * the gate on an unsanctioned deactivation request.
     */
    @Test
    fun `AdminDisableRequestPolicy gates unsanctioned requests and honours unlinkPending, grace, sanctioned, and debounce states`() {
        val now = 2_000_000L

        assertEquals(
            AdminDisableRequestPolicy.Action.LAUNCH_PIN_GATE,
            AdminDisableRequestPolicy.decide(
                paired = true,
                unlinkPending = false,
                setupCompletedOnce = true,
                pinConfigured = true,
                consentPaused = false,
                nowMs = now,
                graceUntilMs = now,
                sanctionedUntilMs = 0L,
                gateSuppressed = false,
                canLaunchFromBackground = true,
            ),
        )
        assertEquals(
            AdminDisableRequestPolicy.Action.RECORD_ATTEMPT_AND_BEST_EFFORT_GATE,
            AdminDisableRequestPolicy.decide(
                paired = true,
                unlinkPending = false,
                setupCompletedOnce = true,
                pinConfigured = true,
                consentPaused = false,
                nowMs = now,
                graceUntilMs = 0L,
                sanctionedUntilMs = 0L,
                gateSuppressed = false,
                canLaunchFromBackground = false,
            ),
        )
        assertEquals(
            "pending unlink must never launch the PIN gate or revive services during admin removal",
            AdminDisableRequestPolicy.Action.ALLOW_WITHOUT_GATE,
            AdminDisableRequestPolicy.decide(
                paired = true,
                unlinkPending = true,
                setupCompletedOnce = true,
                pinConfigured = true,
                consentPaused = false,
                nowMs = now,
                graceUntilMs = 0L,
                sanctionedUntilMs = 0L,
                gateSuppressed = false,
                canLaunchFromBackground = true,
            ),
        )
        assertEquals(
            AdminDisableRequestPolicy.Action.ALREADY_COVERED,
            AdminDisableRequestPolicy.decide(
                paired = true,
                setupCompletedOnce = true,
                pinConfigured = true,
                consentPaused = false,
                nowMs = now,
                graceUntilMs = 0L,
                sanctionedUntilMs = 0L,
                gateSuppressed = true,
                canLaunchFromBackground = true,
            ),
        )
        assertEquals(
            AdminDisableRequestPolicy.Action.ALLOW_WITHOUT_GATE,
            AdminDisableRequestPolicy.decide(
                paired = true,
                setupCompletedOnce = true,
                pinConfigured = true,
                consentPaused = false,
                nowMs = now,
                graceUntilMs = now + 1,
                sanctionedUntilMs = 0L,
                gateSuppressed = false,
                canLaunchFromBackground = true,
            ),
        )
        assertEquals(
            AdminDisableRequestPolicy.Action.ALLOW_WITHOUT_GATE,
            AdminDisableRequestPolicy.decide(
                paired = true,
                setupCompletedOnce = true,
                pinConfigured = true,
                consentPaused = false,
                nowMs = now,
                graceUntilMs = 0L,
                sanctionedUntilMs = now + 1,
                gateSuppressed = false,
                canLaunchFromBackground = true,
            ),
        )
        assertEquals(
            AdminDisableRequestPolicy.Action.ALLOW_WITHOUT_GATE,
            AdminDisableRequestPolicy.decide(
                paired = false,
                setupCompletedOnce = true,
                pinConfigured = true,
                consentPaused = false,
                nowMs = now,
                graceUntilMs = 0L,
                sanctionedUntilMs = 0L,
                gateSuppressed = false,
                canLaunchFromBackground = true,
            ),
        )
        assertEquals(
            AdminDisableRequestPolicy.Action.ALLOW_WITHOUT_GATE,
            AdminDisableRequestPolicy.decide(
                paired = true,
                setupCompletedOnce = false,
                pinConfigured = true,
                consentPaused = false,
                nowMs = now,
                graceUntilMs = 0L,
                sanctionedUntilMs = 0L,
                gateSuppressed = false,
                canLaunchFromBackground = true,
            ),
        )
    }

    /**
     * Ahmed review item 3 (#1303): `manageSpaceActivity` blocks unauthenticated Clear-storage attempts
     * with the PIN gate, and once verified (or already inside the parent's grace window) opens OSRA's
     * management screen (`Re-pair` / `Remove protection`) rather than finishing into a dead-end loop.
     *
     * Mutant: finish without opening management when in grace, or skip PIN when outside grace ->
     * either strands the parent with no reset path or lets the child reach management without PIN.
     */
    @Test
    fun `ManageSpaceGatePolicy requires PIN outside grace and opens management directly inside grace or unpaired`() {
        val now = 5_000_000L
        assertEquals(
            ManageSpaceGatePolicy.Action.REQUIRE_PIN_THEN_OPEN_MANAGEMENT,
            ManageSpaceGatePolicy.decide(
                paired = true,
                unlinkPending = false,
                setupCompletedOnce = true,
                pinConfigured = true,
                consentPaused = false,
                nowMs = now,
                graceUntilMs = now,
                sanctionedUntilMs = 0L,
            ),
        )
        assertEquals(
            ManageSpaceGatePolicy.Action.OPEN_MANAGEMENT_DIRECTLY,
            ManageSpaceGatePolicy.decide(
                paired = true,
                unlinkPending = false,
                setupCompletedOnce = true,
                pinConfigured = true,
                consentPaused = false,
                nowMs = now,
                graceUntilMs = now + 1,
                sanctionedUntilMs = 0L,
            ),
        )
        assertEquals(
            ManageSpaceGatePolicy.Action.OPEN_MANAGEMENT_DIRECTLY,
            ManageSpaceGatePolicy.decide(
                paired = false,
                unlinkPending = false,
                setupCompletedOnce = false,
                pinConfigured = false,
                consentPaused = false,
                nowMs = now,
                graceUntilMs = 0L,
                sanctionedUntilMs = 0L,
            ),
        )
        assertEquals(
            ManageSpaceGatePolicy.Action.FINISH_UNLINKING,
            ManageSpaceGatePolicy.decide(
                paired = true,
                unlinkPending = true,
                setupCompletedOnce = true,
                pinConfigured = true,
                consentPaused = false,
                nowMs = now,
                graceUntilMs = 0L,
                sanctionedUntilMs = 0L,
            ),
        )
    }

    // -------------------------------------------------------------------------
    // 2. UnboundTamperPolicy (Shared-Host Controls + Space Setup)
    // -------------------------------------------------------------------------

    @Test
    fun `UnboundTamperPolicy monitors only in the post-setup degraded state when Accessibility is unbound and not unlinking`() {
        assertTrue(
            UnboundTamperPolicy.shouldMonitor(
                paired = true,
                unlinkPending = false,
                setupCompletedOnce = true,
                pinConfigured = true,
                consentPaused = false,
                accessibilityBound = false,
                canDrawOverlays = true,
                usageAccessGranted = true,
                interactive = true,
            ),
        )
        assertFalse(
            "must stand down immediately when unlinkPending is true",
            UnboundTamperPolicy.shouldMonitor(
                paired = true,
                unlinkPending = true,
                setupCompletedOnce = true,
                pinConfigured = true,
                consentPaused = false,
                accessibilityBound = false,
                canDrawOverlays = true,
                usageAccessGranted = true,
                interactive = true,
            ),
        )
        assertFalse(
            "must sleep when AccessibilityMonitorService is bound",
            UnboundTamperPolicy.shouldMonitor(
                paired = true,
                setupCompletedOnce = true,
                pinConfigured = true,
                consentPaused = false,
                accessibilityBound = true,
                canDrawOverlays = true,
                usageAccessGranted = true,
                interactive = true,
            ),
        )
        assertFalse(
            "must never run before setup completes once",
            UnboundTamperPolicy.shouldMonitor(
                paired = true,
                setupCompletedOnce = false,
                pinConfigured = true,
                consentPaused = false,
                accessibilityBound = false,
                canDrawOverlays = true,
                usageAccessGranted = true,
                interactive = true,
            ),
        )
    }

    /**
     * Codex review (#1303): `UsageEvents` carries no target-package identity, so shared App Info,
     * `DeviceAdminAdd`, and `UninstallerActivity` host screens must return `TamperScreen.NONE` (leaving
     * unrelated apps usable and deferring OSRA-specific unbound actions to own-component callbacks),
     * while phone-wide second-space setup screens remain classified `SPACE_SETUP`.
     *
     * Mutant: match `APP_INFO_CLASSES` / `ADMIN_CLASSES` / `UNINSTALL_CLASSES` in `classifyUnboundTop`
     * -> the shared-host assertions below fail immediately.
     */
    @Test
    fun `UnboundTamperPolicy keeps shared multi-app host screens usable and gates targetless second-space setup`() {
        val ownPkg = "com.osratech.child.full"

        for ((hostPkg, cls) in listOf(
            "com.miui.securitycenter" to "com.miui.appmanager.ApplicationsDetailsActivity",
            "com.android.settings" to "com.android.settings.applications.InstalledAppDetails",
            "com.android.settings" to "com.android.settings.DeviceAdminAdd",
            "com.miui.packageinstaller" to "com.android.packageinstaller.UninstallerActivity",
            "com.android.settings" to "com.android.settings.Settings\$AccessibilitySettingsActivity",
            "com.android.settings" to "com.android.settings.accessibility.AccessibilityDetails",
        )) {
            assertEquals(
                "shared host $hostPkg/$cls must remain NONE without window text",
                TamperScreen.NONE,
                UnboundTamperPolicy.classifyUnboundTop(
                    UnboundTamperPolicy.TopActivity(hostPkg, cls, 1_000L),
                    ownPackage = ownPkg,
                ),
            )
        }

        assertEquals(
            TamperScreen.SPACE_SETUP,
            UnboundTamperPolicy.classifyUnboundTop(
                UnboundTamperPolicy.TopActivity(
                    packageName = "com.samsung.knox.securefolder",
                    className = "com.samsung.knox.securefolder.WelcomeActivity",
                    timestampMs = 1_250L,
                ),
                ownPackage = ownPkg,
            ),
        )
        assertEquals(
            TamperScreen.SPACE_SETUP,
            UnboundTamperPolicy.classifyUnboundTop(
                UnboundTamperPolicy.TopActivity(
                    packageName = "com.samsung.android.da.daagent",
                    className = "com.samsung.android.da.daagent.DualAppActivity",
                    timestampMs = 1_260L,
                ),
                ownPackage = ownPkg,
            ),
        )
    }

    @Test
    fun `UnboundTamperPolicy tracks latest ACTIVITY_RESUMED across lookback and gate transitions`() {
        assertNull(UnboundTamperPolicy.latestResumedActivity(null, emptyList()))

        val events = listOf(
            UnboundTamperPolicy.ResumedEvent("com.miui.home", "com.miui.home.launcher.Launcher", 10_000L, eventType = 1),
            UnboundTamperPolicy.ResumedEvent("com.miui.securitycore", "com.miui.xspace.ui.activity.DualAppActivity", 10_500L, eventType = 1),
            UnboundTamperPolicy.ResumedEvent("com.miui.home", "com.miui.home.launcher.Launcher", 10_550L, eventType = 2),
        )
        val top1 = UnboundTamperPolicy.latestResumedActivity(null, events)
        assertEquals("com.miui.securitycore", top1?.packageName)
        assertEquals("com.miui.xspace.ui.activity.DualAppActivity", top1?.className)

        val top2 = UnboundTamperPolicy.latestResumedActivity(
            top1,
            listOf(
                UnboundTamperPolicy.ResumedEvent("com.osratech.child.full", "com.familyshield.agent.security.TamperGuardTaskActivity", 10_500L, eventType = 1),
            ),
        )
        assertEquals("com.osratech.child.full", top2?.packageName)

        assertFalse(
            UnboundTamperPolicy.shouldLaunchPinGate(
                screen = TamperScreen.SPACE_SETUP,
                pinConfigured = true,
                nowMs = 11_000L,
                graceUntilMs = 130_000L,
                sanctionedUntilMs = 0L,
                gateSuppressed = false,
            ),
        )
    }

    // -------------------------------------------------------------------------
    // 3. Bounded Revival Ceiling + Standing Watchdog + Unlink-Pending Fixtures
    // -------------------------------------------------------------------------

    /**
     * K31 review finding (#1303, 7240384252) + Ahmed item 1:
     * - Row A (cap): 3 revivals inside `REVIVAL_WINDOW_MS` (10 min) schedule fast wakeup; attempt #4
     *   returns `schedule = false` with `capReachedNow = true` once, attempt #5 stays `schedule = false`
     *   with `capReachedNow = false`, and the standing watchdog backs off from `60 s` to `10 min`.
     * - Row B (reset): once 10 minutes elapse (or `bootCount` changes), the window resets cleanly to
     *   `attemptCount = 1, schedule = true` and `60 s` standing interval; healthy (`planEmpty = true`)
     *   standing ticks never consume attempts.
     *
     * Mutant: remove `MAX_REVIVALS_PER_WINDOW` check or window reset -> cap or reset assertion fails.
     */
    @Test
    fun `ServiceRevivalPolicy caps fast revivals at 3 per 10-minute window, logs once, backs off standing watchdog, and resets after window or boot`() {
        var state = ServiceRevivalPolicy.WindowState()
        val t0 = 100_000L

        // Attempts 1, 2, 3 within 10 minutes -> permitted
        for (expectedCount in 1..3) {
            val d = ServiceRevivalPolicy.evaluateExitRevival(
                paired = true,
                consentPaused = false,
                unlinkPending = false,
                explicitlyStopping = false,
                nowElapsedMs = t0 + expectedCount * 2_000L,
                current = state,
                bootCount = 5,
            )
            assertTrue("attempt $expectedCount should schedule", d.schedule)
            assertFalse(d.capReachedNow)
            assertEquals(expectedCount, d.nextState.attemptCount)
            state = d.nextState
        }

        // Standing watchdog backs off from 60 s to 10 min once 3 revivals occurred in window
        assertEquals(
            ServiceRevivalPolicy.REVIVAL_WINDOW_MS,
            ServiceRevivalPolicy.standingWatchdogDelayMs(state, t0 + 10_000L, bootCount = 5),
        )

        // Attempt 4 inside the same 10-minute window -> refused, capReachedNow = true ONCE
        val d4 = ServiceRevivalPolicy.evaluateExitRevival(
            paired = true,
            consentPaused = false,
            nowElapsedMs = t0 + 20_000L,
            current = state,
            bootCount = 5,
        )
        assertFalse("attempt 4 inside 10m must be refused", d4.schedule)
        assertTrue("attempt 4 must report capReachedNow = true once", d4.capReachedNow)
        state = d4.nextState

        // Attempt 5 inside the same window -> still refused, capReachedNow = false (no log spam)
        val d5 = ServiceRevivalPolicy.evaluateExitRevival(
            paired = true,
            consentPaused = false,
            nowElapsedMs = t0 + 30_000L,
            current = state,
            bootCount = 5,
        )
        assertFalse(d5.schedule)
        assertFalse("cap log must fire only once per window", d5.capReachedNow)

        // Reset after 10-minute window expires -> schedules again with attemptCount = 1 and 60 s watchdog
        val afterWindow = (t0 + 2_000L) + ServiceRevivalPolicy.REVIVAL_WINDOW_MS
        assertEquals(
            ServiceRevivalPolicy.STANDING_WATCHDOG_MS,
            ServiceRevivalPolicy.standingWatchdogDelayMs(d5.nextState, afterWindow, bootCount = 5),
        )
        val dReset = ServiceRevivalPolicy.evaluateExitRevival(
            paired = true,
            consentPaused = false,
            nowElapsedMs = afterWindow,
            current = d5.nextState,
            bootCount = 5,
        )
        assertTrue("revival must re-open after 10m window expires", dReset.schedule)
        assertEquals(1, dReset.nextState.attemptCount)

        // Reset across reboot (bootCount 5 -> 6) even if elapsed time is smaller
        val dBootReset = ServiceRevivalPolicy.evaluateExitRevival(
            paired = true,
            consentPaused = false,
            nowElapsedMs = 5_000L,
            current = d4.nextState,
            bootCount = 6,
        )
        assertTrue("reboot must reset the monotonic revival window", dBootReset.schedule)
        assertEquals(1, dBootReset.nextState.attemptCount)

        // Healthy standing-watchdog ticks (planEmpty = true) consume zero attempts
        val healthy = ServiceRevivalPolicy.recordStandingRecovery(
            current = ServiceRevivalPolicy.WindowState(),
            planEmpty = true,
            nowElapsedMs = 50_000L,
            bootCount = 6,
        )
        assertEquals(0, healthy.attemptCount)
        assertTrue(ServiceRevivalPolicy.shouldKeepStandingWatchdog(paired = true, consentPaused = false, unlinkPending = false))
        assertFalse(ServiceRevivalPolicy.shouldKeepStandingWatchdog(paired = true, consentPaused = false, unlinkPending = true))
        assertFalse(ServiceRevivalPolicy.shouldKeepStandingWatchdog(paired = false, consentPaused = false, unlinkPending = false))
    }

    @Test
    fun `queued revival receiver and poll worker recover still-paired active fixture and do nothing during pending unlink`() {
        fun activeDownFixture(unlinkPending: Boolean) = ServiceRecoveryPolicy.State(
            isPaired = true,
            consentPaused = false,
            unlinkPending = unlinkPending,
            filterWanted = true,
            tunnelRunning = false,
            locationMayStart = true,
            locationRunning = false,
            lockActive = true,
            accessibilityEnabled = true,
            accessibilityBound = false,
        )

        // 1. Exit revival broadcast AND standing watchdog broadcast on active fixture -> restarts all 3
        for (action in listOf(
            ServiceRevivalPolicy.ACTION_REVIVE_SERVICES,
            ServiceRevivalPolicy.ACTION_STANDING_WATCHDOG,
        )) {
            val actions = mutableListOf<String>()
            val plan = ServiceRevivalReceiver.handleBroadcast(action) {
                ServiceRecovery.runWith(
                    readState = { activeDownFixture(unlinkPending = false) },
                    restartFilter = { actions += "filter" },
                    restartLocation = { actions += "location" },
                    showLock = { actions += "lock" },
                )
            }
            assertNotNull(plan)
            assertFalse(plan!!.isEmpty)
            assertEquals(listOf("filter", "location", "lock"), actions)
        }

        // 2. Queued ServiceRevivalReceiver during pending unlink (isPaired STILL true!) -> does nothing
        val receiverUnlinkActions = mutableListOf<String>()
        val receiverUnlinkPlan = ServiceRevivalReceiver.handleBroadcast(ServiceRevivalPolicy.ACTION_STANDING_WATCHDOG) {
            ServiceRecovery.runWith(
                readState = { activeDownFixture(unlinkPending = true) },
                restartFilter = { receiverUnlinkActions += "filter" },
                restartLocation = { receiverUnlinkActions += "location" },
                showLock = { receiverUnlinkActions += "lock" },
            )
        }
        assertNotNull(receiverUnlinkPlan)
        assertTrue("pending unlink must yield an empty recovery plan", receiverUnlinkPlan!!.isEmpty)
        assertEquals(emptyList<String>(), receiverUnlinkActions)

        // 3. Queued CommandPollWorker on still-paired active fixture -> restarts all 3
        val workerActiveActions = mutableListOf<String>()
        val workerActivePlan = CommandPollWorker.recoverBeforePoll {
            ServiceRecovery.runWith(
                readState = { activeDownFixture(unlinkPending = false) },
                restartFilter = { workerActiveActions += "filter" },
                restartLocation = { workerActiveActions += "location" },
                showLock = { workerActiveActions += "lock" },
            )
        }
        assertNotNull(workerActivePlan)
        assertEquals(listOf("filter", "location", "lock"), workerActiveActions)

        // 4. Queued CommandPollWorker during pending unlink (isPaired STILL true!) -> does nothing
        val workerUnlinkActions = mutableListOf<String>()
        val workerUnlinkPlan = CommandPollWorker.recoverBeforePoll {
            ServiceRecovery.runWith(
                readState = { activeDownFixture(unlinkPending = true) },
                restartFilter = { workerUnlinkActions += "filter" },
                restartLocation = { workerUnlinkActions += "location" },
                showLock = { workerUnlinkActions += "lock" },
            )
        }
        assertNotNull(workerUnlinkPlan)
        assertTrue("pending unlink must prevent worker recovery restarts", workerUnlinkPlan!!.isEmpty)
        assertEquals(emptyList<String>(), workerUnlinkActions)
    }

    // -------------------------------------------------------------------------
    // 4. MiuiAutostartPolicy & Xiaomi-Scoped RecentsExclusionPolicy
    // -------------------------------------------------------------------------

    @Test
    fun `MiuiAutostartPolicy fails closed on null, never overrides readable denial, and exempts non-Xiaomi`() {
        assertEquals(MiuiAutostartState.ALLOWED, MiuiAutostartPolicy.classifyState("Samsung", null))
        assertTrue(MiuiAutostartPolicy.isAutostartAllowed("Samsung", null, parentConfirmed = false))

        assertEquals(MiuiAutostartState.ALLOWED, MiuiAutostartPolicy.classifyState("Xiaomi", 0))
        assertTrue(MiuiAutostartPolicy.isAutostartAllowed("Redmi", 0, parentConfirmed = false))

        assertEquals(MiuiAutostartState.DENIED, MiuiAutostartPolicy.classifyState("Xiaomi", 1))
        assertFalse(
            "readable denial (MODE_IGNORED = 1) must never be overridable by parent confirmation",
            MiuiAutostartPolicy.isAutostartAllowed("Xiaomi", 1, parentConfirmed = true),
        )

        assertEquals(MiuiAutostartState.UNREADABLE, MiuiAutostartPolicy.classifyState("POCO", null))
        assertFalse(MiuiAutostartPolicy.isAutostartAllowed("POCO", null, parentConfirmed = false))
        assertTrue(MiuiAutostartPolicy.isAutostartAllowed("POCO", null, parentConfirmed = true))
    }

    @Test
    fun `RecentsExclusionPolicy is Xiaomi-specific and preserves existing Samsung Recents behaviour`() {
        assertFalse(RecentsExclusionPolicy.shouldExcludeFromRecents("Xiaomi", paired = false, setupCompletedOnce = false))
        assertFalse(RecentsExclusionPolicy.shouldExcludeFromRecents("Xiaomi", paired = true, setupCompletedOnce = false))
        assertFalse(RecentsExclusionPolicy.shouldExcludeFromRecents("Redmi", paired = false, setupCompletedOnce = true))
        assertTrue(RecentsExclusionPolicy.shouldExcludeFromRecents("Xiaomi", paired = true, setupCompletedOnce = true))
        assertTrue(RecentsExclusionPolicy.shouldExcludeFromRecents("Redmi", paired = true, setupCompletedOnce = true))
        assertTrue(RecentsExclusionPolicy.shouldExcludeFromRecents("POCO", paired = true, setupCompletedOnce = true))

        assertFalse(RecentsExclusionPolicy.shouldExcludeFromRecents("samsung", paired = true, setupCompletedOnce = true))
        assertFalse(RecentsExclusionPolicy.shouldExcludeFromRecents("Samsung", paired = true, setupCompletedOnce = true))
        assertFalse(RecentsExclusionPolicy.shouldExcludeFromRecents("Google", paired = true, setupCompletedOnce = true))
        assertFalse(RecentsExclusionPolicy.shouldExcludeFromRecents(null, paired = true, setupCompletedOnce = true))

        assertTrue(
            ServiceRevivalPolicy.shouldScheduleOnServiceExit(
                paired = true,
                consentPaused = false,
                unlinkPending = false,
                explicitlyStopping = false,
                attemptCountInWindow = 2,
            ),
        )
        assertFalse(
            ServiceRevivalPolicy.shouldScheduleOnServiceExit(
                paired = true,
                consentPaused = false,
                unlinkPending = false,
                explicitlyStopping = false,
                attemptCountInWindow = 3,
            ),
        )
        assertFalse(
            ServiceRevivalPolicy.shouldScheduleOnServiceExit(
                paired = true,
                consentPaused = false,
                unlinkPending = true,
                explicitlyStopping = false,
            ),
        )
        assertFalse(
            ServiceRevivalPolicy.shouldScheduleOnServiceExit(
                paired = true,
                consentPaused = false,
                unlinkPending = false,
                explicitlyStopping = true,
            ),
        )
    }

    // -------------------------------------------------------------------------
    // 5. Discriminating Call-Site Source-Wiring Assertions
    // -------------------------------------------------------------------------

    @Test
    fun `GuardianAdminReceiver and TamperAlertWorker wire policy-gated recovery and immediate plus expedited alert delivery`() {
        val src = stripLineComments(source("app/src/main/java/com/familyshield/agent/security/GuardianAdminReceiver.kt"))
        val body = methodBody(src, "override fun onDisableRequested(")
        val decideIdx = body.indexOf("AdminDisableRequestPolicy.decide(")
        val recoveryIdx = body.indexOf("ServiceRecovery.run(appContext)")
        assertTrue("onDisableRequested must call AdminDisableRequestPolicy.decide", decideIdx >= 0)
        assertTrue(
            "ServiceRecovery.run must run only inside the unsanctioned branch after decide(), never before it",
            recoveryIdx > decideIdx,
        )
        assertTrue(body.contains("unlinkPending = unlinkPending"))
        assertTrue(body.contains("graceUntilMs = TamperState.graceUntil(appContext)"))
        assertTrue(body.contains("sanctionedUntilMs = TamperState.sanctionedRemovalUntil(appContext)"))
        assertTrue(body.contains("GuardAttemptWindow.record("))
        assertTrue(body.contains("TamperAlertWorker.enqueueAndPostGuardTriggeredImmediately("))
        assertTrue(body.contains("TamperGuardTaskActivity::class.java"))

        val workerSrc = stripLineComments(source("app/src/main/java/com/familyshield/agent/security/TamperAlertWorker.kt"))
        val immediateBody = methodBody(workerSrc, "fun enqueueAndPostGuardTriggeredImmediately(")
        assertTrue(immediateBody.contains("TYPE_GUARD_TRIGGERED"))
        assertTrue(immediateBody.contains("entry.apiService().postInternalAlert("))
        assertTrue(immediateBody.contains("guard tamper alert sent directly"))
    }

    @Test
    fun `ServiceRecovery, ServiceRevivalScheduler, DeviceUnlinker, services, worker, and app wire standing watchdog, cap, and unlink cancellation`() {
        val recoverySrc = stripLineComments(source("app/src/main/java/com/familyshield/agent/recovery/ServiceRecovery.kt"))
        val readStateBody = methodBody(recoverySrc, "internal fun readState(")
        assertTrue(readStateBody.contains("val unlinkPending = settings.unlinkPendingSync()"))
        assertTrue(readStateBody.contains("unlinkPending = unlinkPending"))

        val schedulerSrc = stripLineComments(source("app/src/main/java/com/familyshield/agent/recovery/ServiceRevivalScheduler.kt"))
        assertTrue(schedulerSrc.contains("ServiceRevivalPolicy.evaluateExitRevival("))
        assertTrue(schedulerSrc.contains("AlarmManager.ELAPSED_REALTIME,"))
        assertTrue(schedulerSrc.contains("ServiceRevivalPolicy.ACTION_STANDING_WATCHDOG"))

        val unlinkerSrc = stripLineComments(source("app/src/main/java/com/familyshield/agent/network/DeviceUnlinker.kt"))
        assertTrue(unlinkerSrc.contains("stopLocation = { LocationService.stop(context) }"))
        assertTrue(unlinkerSrc.contains("ServiceRevivalScheduler.cancelAll(context)"))

        val locSrc = stripLineComments(source("app/src/main/java/com/familyshield/agent/services/LocationService.kt"))
        val locStart = methodBody(locSrc, "override fun onStartCommand(")
        val locTaskRemoved = methodBody(locSrc, "override fun onTaskRemoved(")
        val locDestroy = methodBody(locSrc, "override fun onDestroy(")
        assertTrue(locStart.contains("if (intent?.action == ACTION_STOP)"))
        assertTrue(locStart.contains("UnboundTamperWatch.ensureStarted(applicationContext)"))
        assertTrue(locStart.contains("ServiceRevivalScheduler.armStandingWatchdogIfNeeded("))
        assertTrue(locTaskRemoved.contains("unlinkPending = settings.unlinkPendingSync()"))
        assertTrue(locTaskRemoved.contains("explicitlyStopping = wasExplicitStop"))
        assertTrue(locDestroy.contains("UnboundTamperWatch.stopIfNoHostRunning()"))
        assertTrue(locDestroy.contains("unlinkPending = settings.unlinkPendingSync()"))
        assertTrue(locDestroy.contains("explicitlyStopping = wasExplicitStop"))

        val vpnSrc = stripLineComments(source("app/src/main/java/com/familyshield/agent/vpn/FilterVpnService.kt"))
        val vpnStart = methodBody(vpnSrc, "override fun onStartCommand(")
        val vpnTaskRemoved = methodBody(vpnSrc, "override fun onTaskRemoved(")
        val vpnDestroy = methodBody(vpnSrc, "override fun onDestroy(")
        assertTrue(vpnStart.contains("ServiceRevivalScheduler.armStandingWatchdogIfNeeded("))
        assertTrue(vpnTaskRemoved.contains("unlinkPending = settings.unlinkPendingSync()"))
        assertTrue(vpnTaskRemoved.contains("explicitlyStopping = wasExplicitStop"))
        assertTrue(vpnDestroy.contains("unlinkPending = settings.unlinkPendingSync()"))
        assertTrue(vpnDestroy.contains("explicitlyStopping = wasExplicitStop"))

        val workerSrc = stripLineComments(source("app/src/main/java/com/familyshield/agent/commands/CommandPollWorker.kt"))
        val doWork = methodBody(workerSrc, "override suspend fun doWork()")
        val recoveryIdx = doWork.indexOf("recoverBeforePoll { com.familyshield.agent.recovery.ServiceRecovery.run(applicationContext) }")
        val skipIdx = doWork.indexOf("IdleCadence.workerShouldPoll(")
        assertTrue("CommandPollWorker.doWork must run ServiceRecovery before workerShouldPoll returns", recoveryIdx in 0 until skipIdx)
    }

    @Test
    fun `GrantChecks, PairingActivity, AccessibilityMonitorService, and TamperGuardTaskActivity wire Xiaomi onboarding and manage-space handoff`() {
        val grantSrc = stripLineComments(source("app/src/main/java/com/familyshield/agent/setup/GrantChecks.kt"))
        val isGrantedBody = methodBody(grantSrc, "fun isGranted(")
        val fixIntentBody = methodBody(grantSrc, "fun fixIntent(")
        assertTrue(isGrantedBody.contains("batteryIgnoringOptimizations() && MiuiAutostartPolicy.isGranted(context)"))
        assertTrue(fixIntentBody.contains("MiuiAutostartPolicy.autostartIntent(context)"))

        val a11ySrc = stripLineComments(source("app/src/main/java/com/familyshield/agent/services/AccessibilityMonitorService.kt"))
        val incompleteBody = methodBody(a11ySrc, "private fun requiredGrantsIncompleteForPairedDevice()")
        assertTrue(
            Regex("""OnboardingPolicy\.rows\(\s*com\.familyshield\.agent\.BuildConfig\.CAPTURE_NOTIFICATIONS,\s*Build\.MANUFACTURER,""").containsMatchIn(incompleteBody),
        )

        val pairingSrc = stripLineComments(source("app/src/main/java/com/familyshield/agent/setup/PairingActivity.kt"))
        val helperBody = methodBody(pairingSrc, "private fun currentOnboardingRows()")
        assertTrue(
            helperBody.contains("OnboardingPolicy.rows(BuildConfig.CAPTURE_NOTIFICATIONS, Build.MANUFACTURER) { grants.isGranted(it) }"),
        )
        assertEquals(1, Regex("""OnboardingPolicy\.rows\(""").findAll(pairingSrc).count())
        assertFalse(pairingSrc.contains("g.required") || pairingSrc.contains("it.grant.required"))
        val recentsBody = methodBody(pairingSrc, "private fun syncRecentsExclusion()")
        assertTrue(recentsBody.contains("if (!MiuiBackgroundPopupPolicy.isXiaomiFamily(Build.MANUFACTURER)) return"))
        assertTrue(recentsBody.contains("RecentsExclusionPolicy.shouldExcludeFromRecents(Build.MANUFACTURER, paired, setupCompleted)"))
        assertTrue(recentsBody.contains("setExcludeFromRecents(exclude)"))
        assertTrue(pairingSrc.contains("EXTRA_OPEN_DEVICE_SETUP"))

        val guardSrc = stripLineComments(source("app/src/main/java/com/familyshield/agent/security/TamperGuardActivity.kt"))
        assertTrue(guardSrc.contains("ManageSpaceGatePolicy.decide("))
        assertTrue(guardSrc.contains("openManagementScreen(this)"))
    }

    private fun stripLineComments(text: String): String =
        text.lineSequence().joinToString("\n") { line ->
            val idx = line.indexOf("//")
            if (idx < 0) line else line.substring(0, idx)
        }

    private fun methodBody(source: String, signaturePrefix: String): String {
        val start = source.indexOf(signaturePrefix)
        assertTrue("missing `$signaturePrefix`", start >= 0)
        var i = start
        var parenDepth = 0
        var bodyOpen = -1
        while (i < source.length) {
            when (source[i]) {
                '(' -> parenDepth++
                ')' -> if (parenDepth > 0) parenDepth--
                '{' -> if (parenDepth == 0) {
                    bodyOpen = i
                    break
                }
                '=' -> if (parenDepth == 0) {
                    val nextDecl = source.indexOf("\n    private fun ", i + 1)
                        .takeIf { it >= 0 } ?: source.indexOf("\n    override fun ", i + 1)
                        .takeIf { it >= 0 } ?: source.length
                    return source.substring(i, nextDecl)
                }
            }
            i++
        }
        assertTrue("missing body brace for `$signaturePrefix`", bodyOpen >= 0)
        var braceDepth = 0
        var cursor = bodyOpen
        while (cursor < source.length) {
            when (source[cursor]) {
                '{' -> braceDepth++
                '}' -> {
                    braceDepth--
                    if (braceDepth == 0) {
                        return source.substring(bodyOpen, cursor + 1)
                    }
                }
            }
            cursor++
        }
        throw AssertionError("unclosed brace for `$signaturePrefix`")
    }

    private fun source(relative: String): String {
        var dir: File? = File(System.getProperty("user.dir") ?: ".").absoluteFile
        while (dir != null) {
            val candidate = File(dir, relative)
            if (candidate.isFile) return candidate.readText()
            dir = dir.parentFile
        }
        throw AssertionError("could not find $relative from ${System.getProperty("user.dir")}")
    }
}
