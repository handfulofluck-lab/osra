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
 * 1. [AdminDisableRequestPolicy] + [GuardianAdminReceiver.onDisableRequested],
 * 2. Target-aware [UnboundTamperPolicy] + own-component `manageSpaceActivity` / `onDisableRequested` callbacks,
 * 3. Durable `unlinkPending` checks in [ServiceRecovery], [ServiceRevivalReceiver], [CommandPollWorker], and service-exit stop paths,
 * 4. [MiuiAutostartPolicy] + Xiaomi `BATTERY` onboarding requirement + Xiaomi-scoped [RecentsExclusionPolicy].
 */
class MiuiGuardAndRevivalSec78Test {

    // -------------------------------------------------------------------------
    // 1. AdminDisableRequestPolicy
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
        // Parent PIN grace window active
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
        // In-app sanctioned removal window active
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
        // Preconditions false -> never gate
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

    // -------------------------------------------------------------------------
    // 2. UnboundTamperPolicy (Target-Aware Scope + Unrelated-App Controls)
    // -------------------------------------------------------------------------

    /**
     * Mutant: monitor while `accessibilityBound == true`, `unlinkPending == true`, or
     * `!setupCompletedOnce`.
     */
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
     * Codex review finding 1 (#1303): shared App Info, DeviceAdminAdd, and UninstallerActivity host
     * classes must NEVER raise a PIN overlay for an unrelated app (`com.google.android.youtube`) or
     * when target identity is unavailable (`targetPackage = null`, where intervention defers to
     * OSRA's own-component callbacks `GuardianAdminReceiver.onDisableRequested` and
     * `android:manageSpaceActivity`).
     *
     * Mutant: remove `if (targetPackage == null || targetPackage != ownPackage) return TamperScreen.NONE`
     * -> the unrelated-app and null-target control assertions below fail immediately.
     */
    @Test
    fun `UnboundTamperPolicy bounds shared host classes to OSRA target identity and keeps unrelated apps usable`() {
        val ownPkg = "com.osratech.child.full"
        val otherPkg = "com.google.android.youtube"

        // 1. Unrelated app controls -> MUST remain NONE (usable without PIN overlay)
        for ((hostPkg, cls) in listOf(
            "com.miui.securitycenter" to "com.miui.appmanager.ApplicationsDetailsActivity",
            "com.android.settings" to "com.android.settings.applications.InstalledAppDetails",
            "com.android.settings" to "com.android.settings.DeviceAdminAdd",
            "com.miui.packageinstaller" to "com.android.packageinstaller.UninstallerActivity",
        )) {
            assertEquals(
                "unrelated app in $hostPkg/$cls must stay NONE",
                TamperScreen.NONE,
                UnboundTamperPolicy.classifyUnboundTop(
                    UnboundTamperPolicy.TopActivity(hostPkg, cls, 1_000L),
                    ownPackage = ownPkg,
                    ourAdminActive = true,
                    targetPackage = otherPkg,
                ),
            )
            assertEquals(
                "unidentified target (null) in $hostPkg/$cls must defer to own-component callbacks",
                TamperScreen.NONE,
                UnboundTamperPolicy.classifyUnboundTop(
                    UnboundTamperPolicy.TopActivity(hostPkg, cls, 1_000L),
                    ownPackage = ownPkg,
                    ourAdminActive = true,
                    targetPackage = null,
                ),
            )
        }

        // 2. Target-aware matches for OSRA's own package -> classified accurately
        assertEquals(
            TamperScreen.APP_INFO,
            UnboundTamperPolicy.classifyUnboundTop(
                UnboundTamperPolicy.TopActivity(
                    packageName = "com.miui.securitycenter",
                    className = "com.miui.appmanager.ApplicationsDetailsActivity",
                    timestampMs = 1_000L,
                ),
                ownPackage = ownPkg,
                ourAdminActive = true,
                targetPackage = ownPkg,
            ),
        )
        assertEquals(
            TamperScreen.DEACTIVATE_ADMIN,
            UnboundTamperPolicy.classifyUnboundTop(
                UnboundTamperPolicy.TopActivity(
                    packageName = "com.android.settings",
                    className = "com.android.settings.DeviceAdminAdd",
                    timestampMs = 1_100L,
                ),
                ownPackage = ownPkg,
                ourAdminActive = true,
                targetPackage = ownPkg,
            ),
        )
        assertEquals(
            "DeviceAdminAdd while our admin is inactive is activation, not tamper",
            TamperScreen.NONE,
            UnboundTamperPolicy.classifyUnboundTop(
                UnboundTamperPolicy.TopActivity(
                    packageName = "com.android.settings",
                    className = "com.android.settings.DeviceAdminAdd",
                    timestampMs = 1_100L,
                ),
                ownPackage = ownPkg,
                ourAdminActive = false,
                targetPackage = ownPkg,
            ),
        )
        assertEquals(
            TamperScreen.UNINSTALL,
            UnboundTamperPolicy.classifyUnboundTop(
                UnboundTamperPolicy.TopActivity(
                    packageName = "com.miui.packageinstaller",
                    className = "com.android.packageinstaller.UninstallerActivity",
                    timestampMs = 1_200L,
                ),
                ownPackage = ownPkg,
                ourAdminActive = true,
                targetPackage = ownPkg,
            ),
        )

        // 3. Phone-wide second-space setup has no target app -> still classified SPACE_SETUP
        assertEquals(
            TamperScreen.SPACE_SETUP,
            UnboundTamperPolicy.classifyUnboundTop(
                UnboundTamperPolicy.TopActivity(
                    packageName = "com.samsung.knox.securefolder",
                    className = "com.samsung.knox.securefolder.WelcomeActivity",
                    timestampMs = 1_250L,
                ),
                ownPackage = ownPkg,
                ourAdminActive = true,
                targetPackage = null,
            ),
        )

        // 4. Accessibility settings hub and service detail page stay open so parent can re-bind OSRA.
        for (cls in listOf(
            "com.android.settings.Settings\$AccessibilitySettingsActivity",
            "com.android.settings.accessibility.AccessibilityDetails",
            "com.samsung.android.settings.accessibility.SecAccessibilityInstalledAppsActivity",
        )) {
            assertEquals(
                cls,
                TamperScreen.NONE,
                UnboundTamperPolicy.classifyUnboundTop(
                    UnboundTamperPolicy.TopActivity("com.android.settings", cls, 1_300L),
                    ownPackage = ownPkg,
                    ourAdminActive = true,
                    targetPackage = ownPkg,
                ),
            )
        }
    }

    @Test
    fun `UnboundTamperPolicy tracks latest ACTIVITY_RESUMED across lookback and gate transitions`() {
        assertNull(UnboundTamperPolicy.latestResumedActivity(null, emptyList()))

        val events = listOf(
            UnboundTamperPolicy.ResumedEvent("com.miui.home", "com.miui.home.launcher.Launcher", 10_000L, eventType = 1),
            UnboundTamperPolicy.ResumedEvent("com.miui.securitycenter", "com.miui.appmanager.ApplicationsDetailsActivity", 10_500L, eventType = 1),
            UnboundTamperPolicy.ResumedEvent("com.miui.home", "com.miui.home.launcher.Launcher", 10_550L, eventType = 2),
        )
        val top1 = UnboundTamperPolicy.latestResumedActivity(null, events)
        assertEquals("com.miui.securitycenter", top1?.packageName)
        assertEquals("com.miui.appmanager.ApplicationsDetailsActivity", top1?.className)

        val top2 = UnboundTamperPolicy.latestResumedActivity(
            top1,
            listOf(
                UnboundTamperPolicy.ResumedEvent("com.osratech.child.full", "com.familyshield.agent.security.TamperGuardTaskActivity", 10_500L, eventType = 1),
            ),
        )
        assertEquals("com.osratech.child.full", top2?.packageName)

        assertFalse(
            UnboundTamperPolicy.shouldLaunchPinGate(
                screen = TamperScreen.APP_INFO,
                pinConfigured = true,
                nowMs = 11_000L,
                graceUntilMs = 130_000L,
                sanctionedUntilMs = 0L,
                gateSuppressed = false,
            ),
        )
    }

    // -------------------------------------------------------------------------
    // 3. Queued Worker & Receiver Unlink-Pending Fixtures (Codex Finding 2)
    // -------------------------------------------------------------------------

    /**
     * Codex review finding 2 (#1303): `DeviceUnlinker` marks `unlinkPending = true` and stops
     * services BEFORE `clearPairing()` runs, so `isPaired` is still `true` during unlink. A queued
     * `CommandPollWorker` or `ServiceRevivalReceiver` must act on a still-paired active fixture
     * (`unlinkPending = false`) and do nothing when `unlinkPending = true`.
     *
     * Mutant: remove `state.unlinkPending` from `ServiceRecoveryPolicy.plan` -> the pending-unlink
     * assertions below restart services and fail.
     */
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

        // 1. Queued ServiceRevivalReceiver on still-paired active fixture -> restarts all 3
        val receiverActiveActions = mutableListOf<String>()
        val receiverActivePlan = ServiceRevivalReceiver.handleBroadcast(ServiceRevivalPolicy.ACTION_REVIVE_SERVICES) {
            ServiceRecovery.runWith(
                readState = { activeDownFixture(unlinkPending = false) },
                restartFilter = { receiverActiveActions += "filter" },
                restartLocation = { receiverActiveActions += "location" },
                showLock = { receiverActiveActions += "lock" },
            )
        }
        assertNotNull(receiverActivePlan)
        assertFalse(receiverActivePlan!!.isEmpty)
        assertEquals(listOf("filter", "location", "lock"), receiverActiveActions)

        // 2. Queued ServiceRevivalReceiver during pending unlink (isPaired STILL true!) -> does nothing
        val receiverUnlinkActions = mutableListOf<String>()
        val receiverUnlinkPlan = ServiceRevivalReceiver.handleBroadcast(ServiceRevivalPolicy.ACTION_REVIVE_SERVICES) {
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
    // 4. MiuiAutostartPolicy, Xiaomi-Scoped RecentsExclusionPolicy, ServiceRevivalPolicy
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

    /**
     * Codex review item 3 (#1303): Recents exclusion is scoped strictly to Xiaomi/Redmi/POCO once
     * paired and setup-complete; Samsung and other vendors keep their existing Recents behaviour.
     */
    @Test
    fun `RecentsExclusionPolicy is Xiaomi-specific and preserves existing Samsung Recents behaviour`() {
        // Xiaomi/Redmi/POCO: excluded only after paired + setup complete
        assertFalse(RecentsExclusionPolicy.shouldExcludeFromRecents("Xiaomi", paired = false, setupCompletedOnce = false))
        assertFalse(RecentsExclusionPolicy.shouldExcludeFromRecents("Xiaomi", paired = true, setupCompletedOnce = false))
        assertFalse(RecentsExclusionPolicy.shouldExcludeFromRecents("Redmi", paired = false, setupCompletedOnce = true))
        assertTrue(RecentsExclusionPolicy.shouldExcludeFromRecents("Xiaomi", paired = true, setupCompletedOnce = true))
        assertTrue(RecentsExclusionPolicy.shouldExcludeFromRecents("Redmi", paired = true, setupCompletedOnce = true))
        assertTrue(RecentsExclusionPolicy.shouldExcludeFromRecents("POCO", paired = true, setupCompletedOnce = true))

        // Samsung, Google, and unknown vendors: never excluded (existing behaviour preserved)
        assertFalse(RecentsExclusionPolicy.shouldExcludeFromRecents("samsung", paired = true, setupCompletedOnce = true))
        assertFalse(RecentsExclusionPolicy.shouldExcludeFromRecents("Samsung", paired = true, setupCompletedOnce = true))
        assertFalse(RecentsExclusionPolicy.shouldExcludeFromRecents("Google", paired = true, setupCompletedOnce = true))
        assertFalse(RecentsExclusionPolicy.shouldExcludeFromRecents(null, paired = true, setupCompletedOnce = true))

        // ServiceRevivalPolicy boundaries
        assertTrue(
            ServiceRevivalPolicy.shouldScheduleOnServiceExit(
                paired = true,
                consentPaused = false,
                unlinkPending = false,
                explicitlyStopping = false,
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
    fun `GuardianAdminReceiver onDisableRequested gates recovery behind AdminDisableRequestPolicy and checks unlinkPending`() {
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
        assertTrue(body.contains("TamperAlertWorker.TYPE_GUARD_TRIGGERED"))
        assertTrue(body.contains("TamperGuardTaskActivity::class.java"))
    }

    @Test
    fun `ServiceRecovery, DeviceUnlinker, services, worker, and app wire durable unlinkPending and explicit stop intents`() {
        val recoverySrc = stripLineComments(source("app/src/main/java/com/familyshield/agent/recovery/ServiceRecovery.kt"))
        val readStateBody = methodBody(recoverySrc, "internal fun readState(")
        assertTrue(readStateBody.contains("val unlinkPending = settings.unlinkPendingSync()"))
        assertTrue(readStateBody.contains("unlinkPending = unlinkPending"))

        val unlinkerSrc = stripLineComments(source("app/src/main/java/com/familyshield/agent/network/DeviceUnlinker.kt"))
        assertTrue(
            "DeviceUnlinker must stop LocationService through LocationService.stop(context) so explicit stop intent is recorded",
            unlinkerSrc.contains("stopLocation = { LocationService.stop(context) }"),
        )

        val locSrc = stripLineComments(source("app/src/main/java/com/familyshield/agent/services/LocationService.kt"))
        val locStart = methodBody(locSrc, "override fun onStartCommand(")
        val locTaskRemoved = methodBody(locSrc, "override fun onTaskRemoved(")
        val locDestroy = methodBody(locSrc, "override fun onDestroy(")
        assertTrue(locStart.contains("if (intent?.action == ACTION_STOP)"))
        assertTrue(locStart.contains("UnboundTamperWatch.ensureStarted(applicationContext)"))
        assertTrue(locTaskRemoved.contains("unlinkPending = settings.unlinkPendingSync()"))
        assertTrue(locTaskRemoved.contains("explicitlyStopping = wasExplicitStop"))
        assertTrue(locDestroy.contains("UnboundTamperWatch.stopIfNoHostRunning()"))
        assertTrue(locDestroy.contains("unlinkPending = settings.unlinkPendingSync()"))
        assertTrue(locDestroy.contains("explicitlyStopping = wasExplicitStop"))

        val vpnSrc = stripLineComments(source("app/src/main/java/com/familyshield/agent/vpn/FilterVpnService.kt"))
        val vpnTaskRemoved = methodBody(vpnSrc, "override fun onTaskRemoved(")
        val vpnDestroy = methodBody(vpnSrc, "override fun onDestroy(")
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
    fun `GrantChecks, PairingActivity, and AccessibilityMonitorService wire Xiaomi BATTERY requirement and Xiaomi-scoped Recents exclusion`() {
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
