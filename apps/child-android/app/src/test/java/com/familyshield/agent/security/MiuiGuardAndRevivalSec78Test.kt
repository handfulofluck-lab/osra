package com.familyshield.agent.security

import com.familyshield.agent.recovery.ServiceRevivalPolicy
import com.familyshield.agent.setup.MiuiAutostartPolicy
import com.familyshield.agent.setup.MiuiAutostartState
import com.familyshield.agent.setup.RecentsExclusionPolicy
import java.io.File
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * osra-security#78: discriminating pure-policy and call-site wiring tests for:
 * 1. [AdminDisableRequestPolicy] + [GuardianAdminReceiver.onDisableRequested],
 * 2. [UnboundTamperPolicy] + [UnboundTamperWatch] degraded-state PIN cover,
 * 3. [MiuiAutostartPolicy] + Xiaomi `BATTERY` onboarding requirement + [RecentsExclusionPolicy],
 * 4. [ServiceRevivalPolicy] + [ServiceRevivalScheduler] + startup/worker recovery hooks.
 */
class MiuiGuardAndRevivalSec78Test {

    // -------------------------------------------------------------------------
    // 1. AdminDisableRequestPolicy
    // -------------------------------------------------------------------------

    /**
     * Mutant: omit grace/sanctioned checks or return ALLOW_WITHOUT_GATE when `canLaunchFromBackground`
     * is true -> either locks out a PIN-verified parent or drops the gate on an unsanctioned request.
     */
    @Test
    fun `AdminDisableRequestPolicy gates unsanctioned requests and honours grace, sanctioned, and debounce states`() {
        val now = 2_000_000L

        assertEquals(
            AdminDisableRequestPolicy.Action.LAUNCH_PIN_GATE,
            AdminDisableRequestPolicy.decide(
                paired = true,
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
        assertEquals(
            AdminDisableRequestPolicy.Action.ALLOW_WITHOUT_GATE,
            AdminDisableRequestPolicy.decide(
                paired = true,
                setupCompletedOnce = true,
                pinConfigured = false,
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
                setupCompletedOnce = true,
                pinConfigured = true,
                consentPaused = true,
                nowMs = now,
                graceUntilMs = 0L,
                sanctionedUntilMs = 0L,
                gateSuppressed = false,
                canLaunchFromBackground = true,
            ),
        )
    }

    // -------------------------------------------------------------------------
    // 2. UnboundTamperPolicy
    // -------------------------------------------------------------------------

    /**
     * Mutant: monitor while `accessibilityBound == true` or `!setupCompletedOnce` -> burns battery in
     * normal operation or blocks App-info restricted-settings during initial setup.
     */
    @Test
    fun `UnboundTamperPolicy monitors only in the post-setup degraded state when Accessibility is unbound`() {
        assertTrue(
            UnboundTamperPolicy.shouldMonitor(
                paired = true,
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
        assertFalse(
            "must sleep while screen is off",
            UnboundTamperPolicy.shouldMonitor(
                paired = true,
                setupCompletedOnce = true,
                pinConfigured = true,
                consentPaused = false,
                accessibilityBound = false,
                canDrawOverlays = true,
                usageAccessGranted = true,
                interactive = false,
            ),
        )
        assertFalse(
            "must respect consent pause (ADR-0008)",
            UnboundTamperPolicy.shouldMonitor(
                paired = true,
                setupCompletedOnce = true,
                pinConfigured = true,
                consentPaused = true,
                accessibilityBound = false,
                canDrawOverlays = true,
                usageAccessGranted = true,
                interactive = true,
            ),
        )
    }

    /**
     * Mutant: ignore `ApplicationsDetailsActivity` or `DeviceAdminAdd`, or gate `AccessibilityDetails`
     * -> either misses App-info / admin deactivation while unbound or blocks parent Accessibility re-bind.
     */
    @Test
    fun `UnboundTamperPolicy classifies MIUI App-info, DeviceAdminAdd, and Uninstaller while leaving Accessibility settings open`() {
        val ownPkg = "com.osratech.child.full"

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
            ),
        )
        assertEquals(
            "AppManagerMainActivity list without window text stays NONE in unbound class-only fallback",
            TamperScreen.NONE,
            UnboundTamperPolicy.classifyUnboundTop(
                UnboundTamperPolicy.TopActivity(
                    packageName = "com.miui.securitycenter",
                    className = "com.miui.appmanager.AppManagerMainActivity",
                    timestampMs = 1_000L,
                ),
                ownPackage = ownPkg,
                ourAdminActive = true,
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
            ),
        )
        // Accessibility settings hub and service detail page must stay open so parent can re-bind OSRA.
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
                ),
            )
        }
        assertEquals(
            TamperScreen.NONE,
            UnboundTamperPolicy.classifyUnboundTop(
                UnboundTamperPolicy.TopActivity(ownPkg, "com.familyshield.agent.security.TamperGuardTaskActivity", 1_400L),
                ownPackage = ownPkg,
                ourAdminActive = true,
            ),
        )
    }

    /**
     * Mutant: drop non-resume filtering or break same-millisecond tie-breaking -> stale activity wins.
     */
    @Test
    fun `UnboundTamperPolicy tracks latest ACTIVITY_RESUMED across lookback and gate transitions`() {
        assertNull(UnboundTamperPolicy.latestResumedActivity(null, emptyList()))

        val events = listOf(
            UnboundTamperPolicy.ResumedEvent("com.miui.home", "com.miui.home.launcher.Launcher", 10_000L, eventType = 1),
            UnboundTamperPolicy.ResumedEvent("com.miui.securitycenter", "com.miui.appmanager.ApplicationsDetailsActivity", 10_500L, eventType = 1),
            // ACTIVITY_PAUSED (2) for launcher arriving after 10_500 must NOT overwrite resumed top!
            UnboundTamperPolicy.ResumedEvent("com.miui.home", "com.miui.home.launcher.Launcher", 10_550L, eventType = 2),
        )
        val top1 = UnboundTamperPolicy.latestResumedActivity(null, events)
        assertEquals("com.miui.securitycenter", top1?.packageName)
        assertEquals("com.miui.appmanager.ApplicationsDetailsActivity", top1?.className)

        // Same-timestamp tie goes to the later event in the cursor (e.g. fast redirect intoTamperGuardTaskActivity)
        val top2 = UnboundTamperPolicy.latestResumedActivity(
            top1,
            listOf(
                UnboundTamperPolicy.ResumedEvent("com.osratech.child.full", "com.familyshield.agent.security.TamperGuardTaskActivity", 10_500L, eventType = 1),
            ),
        )
        assertEquals("com.osratech.child.full", top2?.packageName)

        // Grace window suppresses gate launch after parent enters valid PIN
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
        assertTrue(
            UnboundTamperPolicy.shouldLaunchPinGate(
                screen = TamperScreen.APP_INFO,
                pinConfigured = true,
                nowMs = 130_000L,
                graceUntilMs = 130_000L,
                sanctionedUntilMs = 0L,
                gateSuppressed = false,
            ),
        )
    }

    // -------------------------------------------------------------------------
    // 3. MiuiAutostartPolicy, RecentsExclusionPolicy, ServiceRevivalPolicy
    // -------------------------------------------------------------------------

    /**
     * Mutant: allow `parentConfirmed = true` to override a readable `MODE_IGNORED` (`1`) on Xiaomi ->
     * lets onboarding mark Autostart granted while MIUI still blocks revival.
     */
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
    fun `RecentsExclusionPolicy and ServiceRevivalPolicy enforce onboarding and explicit-stop boundaries`() {
        assertFalse(RecentsExclusionPolicy.shouldExcludeFromRecents(paired = false, setupCompletedOnce = false))
        assertFalse(RecentsExclusionPolicy.shouldExcludeFromRecents(paired = true, setupCompletedOnce = false))
        assertFalse(RecentsExclusionPolicy.shouldExcludeFromRecents(paired = false, setupCompletedOnce = true))
        assertTrue(RecentsExclusionPolicy.shouldExcludeFromRecents(paired = true, setupCompletedOnce = true))

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
                unlinkPending = false,
                explicitlyStopping = true,
            ),
        )
        assertFalse(
            ServiceRevivalPolicy.shouldScheduleOnServiceExit(
                paired = true,
                consentPaused = true,
                unlinkPending = false,
                explicitlyStopping = false,
            ),
        )
        assertFalse(
            ServiceRevivalPolicy.shouldScheduleOnServiceExit(
                paired = false,
                consentPaused = false,
                unlinkPending = false,
                explicitlyStopping = false,
            ),
        )
        assertFalse(ServiceRevivalPolicy.shouldRunStartupRecovery(unlinkPending = true))
        assertTrue(ServiceRevivalPolicy.shouldRunStartupRecovery(unlinkPending = false))
    }

    // -------------------------------------------------------------------------
    // 4. Discriminating Call-Site Source-Wiring Assertions
    // -------------------------------------------------------------------------

    /**
     * Mutant: remove `ServiceRecovery.run(appContext)`, `AdminDisableRequestPolicy.decide(...)`, or
     * `TamperGuardTaskActivity::class.java` from `GuardianAdminReceiver.onDisableRequested`.
     */
    @Test
    fun `GuardianAdminReceiver onDisableRequested wires recovery, policy decision, alert window, and PIN gate`() {
        val src = stripLineComments(source("app/src/main/java/com/familyshield/agent/security/GuardianAdminReceiver.kt"))
        val body = methodBody(src, "override fun onDisableRequested(")
        assertTrue(body.contains("ServiceRecovery.run(appContext)"))
        assertTrue(body.contains("AdminDisableRequestPolicy.decide("))
        assertTrue(body.contains("graceUntilMs = TamperState.graceUntil(appContext)"))
        assertTrue(body.contains("sanctionedUntilMs = TamperState.sanctionedRemovalUntil(appContext)"))
        assertTrue(body.contains("GuardAttemptWindow.record("))
        assertTrue(body.contains("TamperAlertWorker.TYPE_GUARD_TRIGGERED"))
        assertTrue(body.contains("TamperGuardTaskActivity::class.java"))
    }

    /**
     * Mutant: drop `UnboundTamperWatch.ensureStarted` or `ServiceRevivalScheduler.scheduleIfNeeded`
     * from `LocationService`, `FilterVpnService`, `CommandPollWorker`, or `FamilyShieldApp`.
     */
    @Test
    fun `foreground services, CommandPollWorker, and FamilyShieldApp wire unbound watch and service revival`() {
        val locSrc = stripLineComments(source("app/src/main/java/com/familyshield/agent/services/LocationService.kt"))
        val locStart = methodBody(locSrc, "override fun onStartCommand(")
        val locTaskRemoved = methodBody(locSrc, "override fun onTaskRemoved(")
        val locDestroy = methodBody(locSrc, "override fun onDestroy(")
        assertTrue(locStart.contains("UnboundTamperWatch.ensureStarted(applicationContext)"))
        assertTrue(locTaskRemoved.contains("ServiceRevivalScheduler.scheduleIfNeeded("))
        assertTrue(locDestroy.contains("UnboundTamperWatch.stopIfNoHostRunning()"))
        assertTrue(locDestroy.contains("ServiceRevivalScheduler.scheduleIfNeeded("))

        val vpnSrc = stripLineComments(source("app/src/main/java/com/familyshield/agent/vpn/FilterVpnService.kt"))
        val vpnCreate = methodBody(vpnSrc, "override fun onCreate(")
        val vpnStart = methodBody(vpnSrc, "override fun onStartCommand(")
        val vpnTaskRemoved = methodBody(vpnSrc, "override fun onTaskRemoved(")
        val vpnDestroy = methodBody(vpnSrc, "override fun onDestroy(")
        assertTrue(vpnCreate.contains("UnboundTamperWatch.ensureStarted(applicationContext)"))
        assertTrue(vpnStart.contains("explicitStopRequested = true"))
        assertTrue(vpnStart.contains("explicitStopRequested = false"))
        assertTrue(vpnStart.contains("UnboundTamperWatch.ensureStarted(applicationContext)"))
        assertTrue(vpnTaskRemoved.contains("explicitlyStopping = explicitStopRequested"))
        assertTrue(vpnDestroy.contains("UnboundTamperWatch.stopIfNoHostRunning()"))
        assertTrue(vpnDestroy.contains("explicitlyStopping = wasExplicitStop"))

        val workerSrc = stripLineComments(source("app/src/main/java/com/familyshield/agent/commands/CommandPollWorker.kt"))
        val doWork = methodBody(workerSrc, "override suspend fun doWork()")
        val recoveryIdx = doWork.indexOf("ServiceRecovery.run(applicationContext)")
        val skipIdx = doWork.indexOf("IdleCadence.workerShouldPoll(")
        assertTrue("CommandPollWorker.doWork must run ServiceRecovery before workerShouldPoll returns", recoveryIdx in 0 until skipIdx)

        val appSrc = stripLineComments(source("app/src/main/java/com/familyshield/agent/FamilyShieldApp.kt"))
        val appCreate = methodBody(appSrc, "override fun onCreate(")
        assertTrue(appCreate.contains("ServiceRevivalPolicy.shouldRunStartupRecovery(unlinkPending)"))
        assertTrue(appCreate.contains("ServiceRecovery.run(this@FamilyShieldApp)"))
    }

    /**
     * Mutant: leave any `OnboardingPolicy.rows` call without `Build.MANUFACTURER`, keep reading
     * `g.required` instead of `row.required` in `PairingActivity`, or omit `MiuiAutostartPolicy` in `GrantChecks`.
     */
    @Test
    fun `GrantChecks, PairingActivity, and AccessibilityMonitorService wire Xiaomi BATTERY requirement and Recents exclusion`() {
        val grantSrc = stripLineComments(source("app/src/main/java/com/familyshield/agent/setup/GrantChecks.kt"))
        val isGrantedBody = methodBody(grantSrc, "fun isGranted(")
        val fixIntentBody = methodBody(grantSrc, "fun fixIntent(")
        assertTrue(isGrantedBody.contains("batteryIgnoringOptimizations() && MiuiAutostartPolicy.isGranted(context)"))
        assertTrue(fixIntentBody.contains("MiuiAutostartPolicy.autostartIntent(context)"))

        val a11ySrc = stripLineComments(source("app/src/main/java/com/familyshield/agent/services/AccessibilityMonitorService.kt"))
        val incompleteBody = methodBody(a11ySrc, "private fun requiredGrantsIncompleteForPairedDevice()")
        assertTrue(
            "AccessibilityMonitorService must pass Build.MANUFACTURER to OnboardingPolicy.rows",
            Regex("""OnboardingPolicy\.rows\(\s*com\.familyshield\.agent\.BuildConfig\.CAPTURE_NOTIFICATIONS,\s*Build\.MANUFACTURER,""").containsMatchIn(incompleteBody),
        )

        val pairingSrc = stripLineComments(source("app/src/main/java/com/familyshield/agent/setup/PairingActivity.kt"))
        val helperBody = methodBody(pairingSrc, "private fun currentOnboardingRows()")
        assertTrue(
            helperBody.contains("OnboardingPolicy.rows(BuildConfig.CAPTURE_NOTIFICATIONS, Build.MANUFACTURER) { grants.isGranted(it) }"),
        )
        assertEquals(
            "every OnboardingPolicy.rows call in PairingActivity must go through currentOnboardingRows()",
            1,
            Regex("""OnboardingPolicy\.rows\(""").findAll(pairingSrc).count(),
        )
        assertFalse(
            "PairingActivity must read row.required / it.required so Xiaomi BATTERY is enforced as required",
            pairingSrc.contains("g.required") || pairingSrc.contains("it.grant.required"),
        )
        val recentsBody = methodBody(pairingSrc, "private fun syncRecentsExclusion()")
        assertTrue(recentsBody.contains("RecentsExclusionPolicy.shouldExcludeFromRecents(paired, setupCompleted)"))
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
        // Find opening '{' after parameter list (skipping nested parentheses in parameters)
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
                    // Single-expression function: return until next top-level declaration or end of line block
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
