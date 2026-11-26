package com.familyshield.agent.setup

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File

/**
 * C-05 First run (#1179) + #1174 (permissions before pairing, 3-path setup completion gate,
 * deduplicated missing-permissions alert, no premature tamper/block alerts) + osra-security#80
 * (one-way completion latch so revoking a grant after setup never suppresses enforcement) +
 * osra-security#78 (Xiaomi/MIUI background pop-up op 10021/10020 required inside OVERLAY) +
 * U74 fix 1 ("Open app info" straight after step 1 of the #1176 restricted-settings guide).
 */
class FirstRunOrderPolicyTest {

    @Test
    fun `unpaired first launch starts on welcome before permissions or pairing`() {
        assertEquals(
            PrePairStage.WELCOME,
            FirstRunOrderPolicy.resolveUnpairedStage(
                welcomeCompleted = false,
                requiredGrantsReady = false,
                forceChecklist = false,
                hasTypedOrScannedPairing = false,
                c05Enabled = true,
            ),
        )
    }

    @Test
    fun `after welcome with missing required grants setup runs permissions before pairing`() {
        assertEquals(
            PrePairStage.PRE_PAIR_PERMISSIONS,
            FirstRunOrderPolicy.resolveUnpairedStage(
                welcomeCompleted = true,
                requiredGrantsReady = false,
                forceChecklist = false,
                hasTypedOrScannedPairing = false,
                c05Enabled = true,
            ),
        )
        assertEquals(
            PrePairStage.PRE_PAIR_CHECKLIST,
            FirstRunOrderPolicy.resolveUnpairedStage(
                welcomeCompleted = true,
                requiredGrantsReady = false,
                forceChecklist = true,
                hasTypedOrScannedPairing = false,
                c05Enabled = true,
            ),
        )
    }

    @Test
    fun `once all required grants are ready unpaired setup advances to pairing form`() {
        assertEquals(
            PrePairStage.PAIRING_FORM,
            FirstRunOrderPolicy.resolveUnpairedStage(
                welcomeCompleted = true,
                requiredGrantsReady = true,
                forceChecklist = false,
                hasTypedOrScannedPairing = false,
                c05Enabled = true,
            ),
        )
        assertEquals(
            PrePairStage.PAIRING_FORM,
            FirstRunOrderPolicy.resolveUnpairedStage(
                welcomeCompleted = true,
                requiredGrantsReady = true,
                forceChecklist = true,
                hasTypedOrScannedPairing = false,
                c05Enabled = true,
            ),
        )
    }

    @Test
    fun `flag off keeps legacy welcome-to-pairing order and typed or scanned state preserves form`() {
        assertEquals(
            PrePairStage.PAIRING_FORM,
            FirstRunOrderPolicy.resolveUnpairedStage(
                welcomeCompleted = true,
                requiredGrantsReady = false,
                forceChecklist = false,
                hasTypedOrScannedPairing = false,
                c05Enabled = false,
            ),
        )
        assertEquals(
            PrePairStage.PAIRING_FORM,
            FirstRunOrderPolicy.resolveUnpairedStage(
                welcomeCompleted = false,
                requiredGrantsReady = false,
                forceChecklist = false,
                hasTypedOrScannedPairing = true,
                c05Enabled = true,
            ),
        )
    }

    @Test
    fun `enforcement is suppressed only before first completion and never after revoking a grant post-setup`() {
        // Fresh never-completed paired device -> suppresses all 3 paths until required grants finish.
        assertTrue(
            FirstRunOrderPolicy.shouldSuppressEnforcement(
                paired = true,
                requiredGrantsReady = false,
                setupCompletedOnce = false,
            ),
        )
        // Fresh paired device with all required grants ready -> enforces immediately.
        assertFalse(
            FirstRunOrderPolicy.shouldSuppressEnforcement(
                paired = true,
                requiredGrantsReady = true,
                setupCompletedOnce = false,
            ),
        )
        // osra-security#80 regression: once setup completed once, losing PRIVATE_DNS, WEB_FILTER,
        // LOCATION, OVERLAY, or USAGE_ACCESS must NEVER suppress enforcement.
        for (revoked in listOf(
            OnboardingPolicy.Grant.PRIVATE_DNS,
            OnboardingPolicy.Grant.WEB_FILTER,
            OnboardingPolicy.Grant.LOCATION,
            OnboardingPolicy.Grant.OVERLAY,
            OnboardingPolicy.Grant.USAGE_ACCESS,
        )) {
            val rowsAfterRevoke = OnboardingPolicy.rows { it != revoked }
            assertFalse("sanity: revoking $revoked makes canComplete false", OnboardingPolicy.canComplete(rowsAfterRevoke))
            assertFalse(
                "revoking $revoked after first completion must NOT suppress enforcement",
                FirstRunOrderPolicy.shouldSuppressEnforcement(
                    paired = true,
                    requiredGrantsReady = OnboardingPolicy.canComplete(rowsAfterRevoke),
                    setupCompletedOnce = true,
                ),
            )
        }
        // Unpaired devices never enter paired enforcement suppression.
        assertFalse(
            FirstRunOrderPolicy.shouldSuppressEnforcement(
                paired = false,
                requiredGrantsReady = false,
                setupCompletedOnce = false,
            ),
        )
    }

    @Test
    fun `missing-permissions alert deduplicates per fingerprint and stops after completion`() {
        val fp1 = FirstRunOrderPolicy.missingGrantsFingerprint(
            listOf(OnboardingPolicy.Grant.WEB_FILTER, OnboardingPolicy.Grant.OVERLAY),
        )
        val fp1Reordered = FirstRunOrderPolicy.missingGrantsFingerprint(
            listOf(OnboardingPolicy.Grant.OVERLAY, OnboardingPolicy.Grant.WEB_FILTER),
        )
        assertEquals(fp1, fp1Reordered)
        assertTrue(FirstRunOrderPolicy.shouldEnqueueMissingAlert(true, false, fp1, null))
        assertFalse("same missing set must not repeat", FirstRunOrderPolicy.shouldEnqueueMissingAlert(true, false, fp1, fp1))
        val fp2 = FirstRunOrderPolicy.missingGrantsFingerprint(listOf(OnboardingPolicy.Grant.WEB_FILTER))
        assertTrue("smaller missing set updates single row", FirstRunOrderPolicy.shouldEnqueueMissingAlert(true, false, fp2, fp1))
        assertFalse("after completion never sends missing-permissions alert", FirstRunOrderPolicy.shouldEnqueueMissingAlert(true, true, fp2, null))
        assertFalse("unpaired never sends alert", FirstRunOrderPolicy.shouldEnqueueMissingAlert(false, false, fp1, null))

        val body = FirstRunOrderPolicy.missingPermissionsAlertBody(listOf("Display over other apps", "Web filter"))
        assertTrue(body.contains("Display over other apps, Web filter"))
    }

    @Test
    fun `osra-security-80 upgrade path seeds latch without suppressing blocking and alerts once for newly required grants`() {
        // (a) Pre-upgrade already-paired device updating to this build without NOTIFICATION_LISTENER:
        // migration runs once, seeds completion latch without checking live grants, keeps blocking ON,
        // and emits ONE deduplicated setup_incomplete alert for the newly required missing grant.
        val upgradeDecision = FirstRunOrderPolicy.upgradeSeedDecision(
            upgradeMigrated = false,
            hasExistingPairedDeviceId = true,
            alreadyLatched = false,
        )
        assertTrue("pre-upgrade paired device must seed completion latch", upgradeDecision.seedLatch)
        assertTrue("migration flag must be recorded", upgradeDecision.markMigrated)

        val missingRows = OnboardingPolicy.rows(notificationCaptureAvailable = true) {
            it != OnboardingPolicy.Grant.NOTIFICATION_LISTENER
        }
        val missingGrants = OnboardingPolicy.missingRequired(missingRows)
        assertEquals(listOf(OnboardingPolicy.Grant.NOTIFICATION_LISTENER), missingGrants)
        assertFalse(
            "upgraded device missing newly required grant must NOT suppress enforcement",
            FirstRunOrderPolicy.shouldSuppressEnforcement(
                paired = true,
                requiredGrantsReady = OnboardingPolicy.canComplete(missingRows),
                setupCompletedOnce = upgradeDecision.seedLatch,
            ),
        )
        val fp = FirstRunOrderPolicy.missingGrantsFingerprint(missingGrants)
        assertTrue(
            "upgraded device reports newly required missing grant once",
            FirstRunOrderPolicy.shouldEnqueueMissingAlert(
                paired = true,
                setupCompletedOnce = true,
                currentFingerprint = fp,
                lastNotifiedFingerprint = null,
                upgradeSeeded = true,
            ),
        )
        assertFalse(
            "upgraded device must not repeat identical missing-grant alert",
            FirstRunOrderPolicy.shouldEnqueueMissingAlert(
                paired = true,
                setupCompletedOnce = true,
                currentFingerprint = fp,
                lastNotifiedFingerprint = fp,
                upgradeSeeded = true,
            ),
        )
        assertFalse(
            "queued alert for upgrade-seeded missing grant is allowed to send before completion",
            FirstRunOrderPolicy.shouldDropSetupIncompleteAtSendTime(
                setupCompletedOnce = true,
                upgradeSeededWithMissingGrants = true,
            ),
        )
    }

    @Test
    fun `fresh pairing on this build still suppresses until first completion and drops late queued setup_incomplete`() {
        // (b) Fresh pairing after migration flag is set (including after unpair/re-pair):
        // never mistaken for an upgrade -> suppresses until first completion, enqueues missing alert once.
        val freshDecision = FirstRunOrderPolicy.upgradeSeedDecision(
            upgradeMigrated = true,
            hasExistingPairedDeviceId = true,
            alreadyLatched = false,
        )
        assertFalse("fresh pairing must NOT be seeded as an upgrade", freshDecision.seedLatch)
        assertFalse("migration already done", freshDecision.markMigrated)
        assertTrue(
            "fresh never-completed pairing suppresses enforcement while required grants are missing",
            FirstRunOrderPolicy.shouldSuppressEnforcement(
                paired = true,
                requiredGrantsReady = false,
                setupCompletedOnce = false,
            ),
        )
        val fp = FirstRunOrderPolicy.missingGrantsFingerprint(listOf(OnboardingPolicy.Grant.OVERLAY))
        assertTrue(
            FirstRunOrderPolicy.shouldEnqueueMissingAlert(
                paired = true,
                setupCompletedOnce = false,
                currentFingerprint = fp,
                lastNotifiedFingerprint = null,
                upgradeSeeded = false,
            ),
        )

        // (c) After first completion, revoking a grant never suppresses enforcement and any queued
        // setup_incomplete:<deviceId> alert still sitting in WorkManager is dropped at send time.
        assertFalse(
            FirstRunOrderPolicy.shouldSuppressEnforcement(
                paired = true,
                requiredGrantsReady = false,
                setupCompletedOnce = true,
            ),
        )
        assertTrue(
            "queued setup_incomplete notice must be dropped at send time once setup completed",
            FirstRunOrderPolicy.shouldDropSetupIncompleteAtSendTime(
                setupCompletedOnce = true,
                upgradeSeededWithMissingGrants = false,
            ),
        )
        assertFalse(
            "queued setup_incomplete notice stays sendable while initial setup is still incomplete",
            FirstRunOrderPolicy.shouldDropSetupIncompleteAtSendTime(
                setupCompletedOnce = false,
                upgradeSeededWithMissingGrants = false,
            ),
        )
        assertEquals(
            "setup_incomplete:dev-42",
            com.familyshield.agent.security.TamperAlertWorker.dedupeKeyFor(
                type = com.familyshield.agent.security.TamperAlertWorker.TYPE_SETUP_INCOMPLETE,
                deviceId = "dev-42",
                guardWindow = null,
                app = "OVERLAY",
                layout = "",
                eventAtMs = 0L,
                adminRemovedAtMs = 0L,
            ),
        )
    }

    @Test
    fun `Xiaomi MIUI background pop-up op 10021 and lock-screen op 10020 gate OVERLAY completion`() {
        assertTrue(MiuiBackgroundPopupPolicy.isXiaomiFamily("Xiaomi"))
        assertTrue(MiuiBackgroundPopupPolicy.isXiaomiFamily("Redmi"))
        assertTrue(MiuiBackgroundPopupPolicy.isXiaomiFamily("POCO"))
        assertFalse(MiuiBackgroundPopupPolicy.isXiaomiFamily("samsung"))
        assertFalse(MiuiBackgroundPopupPolicy.isXiaomiFamily("Google"))

        // Non-Xiaomi never blocked by MIUI ops.
        assertTrue(MiuiBackgroundPopupPolicy.isBackgroundPopupAllowed("samsung", op10021Mode = 1, op10020Mode = 1))
        // Xiaomi with 10021 = ignore (1) -> setup must NOT complete.
        assertFalse(MiuiBackgroundPopupPolicy.isBackgroundPopupAllowed("Xiaomi", op10021Mode = 1, op10020Mode = 0))
        // Xiaomi with 10020 = ignore (1) -> setup must NOT complete.
        assertFalse(MiuiBackgroundPopupPolicy.isBackgroundPopupAllowed("Redmi", op10021Mode = 0, op10020Mode = 1))
        // Xiaomi with both allowed (0) -> complete.
        assertTrue(MiuiBackgroundPopupPolicy.isBackgroundPopupAllowed("Redmi", op10021Mode = 0, op10020Mode = 0))
    }

    @Test
    fun `wiring covers all 3 protection paths, setup-alert gate, MIUI check, U74 button, and Bureau copy`() {
        val root = findAppSrcRoot()
        val screens = File(root, "java/com/familyshield/agent/ui/pairing/OnboardingWelcomeAndStepsScreen.kt").readText()
        val activity = File(root, "java/com/familyshield/agent/setup/PairingActivity.kt").readText()
        val service = File(root, "java/com/familyshield/agent/services/AccessibilityMonitorService.kt").readText()
        val grantChecks = File(root, "java/com/familyshield/agent/setup/GrantChecks.kt").readText()
        val worker = File(root, "java/com/familyshield/agent/security/TamperAlertWorker.kt").readText()
        val blockActivity = File(root, "java/com/familyshield/agent/enforcement/BlockActivity.kt").readText()
        val settings = File(root, "java/com/familyshield/agent/data/AgentSettings.kt").readText()
        val enStrings = File(root, "res/values/strings.xml").readText()
        val arStrings = File(root, "res/values-ar/strings.xml").readText()

        // U74 fix 1: Open app info button sits inside the step loop right after step 1 (index == 0).
        val stepLoopIdx = screens.indexOf("guide.steps.forEachIndexed")
        val openAppInfoIdx = screens.indexOf("index == 0 && onOpenAppInfo != null")
        val waitingLineIdx = screens.indexOf("guide.waitingLine")
        assertTrue("U74 button condition missing", openAppInfoIdx > stepLoopIdx && openAppInfoIdx < waitingLineIdx)
        assertTrue("Agreement-last composable missing", screens.contains("fun OnboardingFamilyAgreementScreen("))
        assertTrue("Transparency card composable missing", screens.contains("private fun OsraTransparencyCard("))

        // #1174 + osra-security#80: PairingActivity routes unpaired flow and latches completion.
        val policySource = File(root, "java/com/familyshield/agent/setup/FirstRunOrderPolicy.kt").readText()
        assertTrue(activity.contains("FirstRunOrderPolicy.resolveUnpairedStage("))
        assertTrue(activity.contains("SetupCompletionStore.markCompleted("))
        assertTrue(activity.contains("SetupCompletionStore.seedUpgradeLatchIfNeeded("))
        assertTrue(activity.contains("SetupCompletionStore.markUpgradeMigrated("))
        assertTrue(activity.contains("OnboardingFamilyAgreementScreen("))
        assertTrue(activity.contains("ChildUxFlags.c05FirstRunEnabled"))
        assertTrue(settings.contains("SetupCompletionStore.clear(context)"))
        assertTrue(settings.contains("SetupCompletionStore.markUpgradeMigrated(context)"))
        assertTrue(service.contains("SetupCompletionStore.seedUpgradeLatchIfNeeded("))
        assertTrue(worker.contains("SetupCompletionStore.seedUpgradeLatchIfNeeded("))
        assertTrue(worker.contains("FirstRunOrderPolicy.shouldDropSetupIncompleteAtSendTime("))
        assertTrue(blockActivity.contains("SetupCompletionStore.seedUpgradeLatchIfNeeded("))
        val clearFn = policySource.substringAfter("fun clear(context: Context)").substringBefore("private fun prefs(")
        assertTrue("SetupCompletionStore.clear must preserve KEY_UPGRADE_MIGRATED", clearFn.contains("putBoolean(KEY_UPGRADE_MIGRATED, true)"))

        // All 3 protection paths in AccessibilityMonitorService gated by requiredGrantsIncompleteForPairedDevice():
        val path1Guard = service.substringAfter("private fun guardProtectionScreens(").substringBefore("private fun stepIn(")
        val path1Cover = service.substringAfter("private fun coverSharedProtectionScreens(").substringBefore("private fun removeGuardCover(")
        val path2Filter = service.substringAfter("private fun enforceFilterRecovery(").substringBefore("private fun updateFilterRecoveryCovers(")
        val path3Blocks = service.substringAfter("private fun enforceVisibleBlocks(").substringBefore("private fun dismissPictureInPicture(")
        assertTrue("Path 1 guardProtectionScreens must check setup gate", path1Guard.contains("requiredGrantsIncompleteForPairedDevice()"))
        assertTrue("Path 1 coverSharedProtectionScreens must check setup gate", path1Cover.contains("requiredGrantsIncompleteForPairedDevice()"))
        assertTrue("Path 2 enforceFilterRecovery must check setup gate", path2Filter.contains("requiredGrantsIncompleteForPairedDevice()"))
        assertTrue("Path 3 enforceVisibleBlocks must check setup gate", path3Blocks.contains("requiredGrantsIncompleteForPairedDevice()"))
        assertTrue("Missing-permissions alert must enqueue TYPE_SETUP_INCOMPLETE", service.contains("TamperAlertWorker.TYPE_SETUP_INCOMPLETE"))

        // Premature tamper and app_blocked alerts suppressed until setup completes once.
        assertTrue(worker.contains("TYPE_SETUP_INCOMPLETE"))
        assertTrue(worker.contains("SetupCompletionStore.isCompletedForDevice("))
        assertTrue(blockActivity.contains("SetupCompletionStore.isCompletedForDevice("))

        // Xiaomi/MIUI background pop-up wired into GrantChecks OVERLAY.
        assertTrue(grantChecks.contains("MiuiBackgroundPopupPolicy.isGranted(context)"))
        assertTrue(grantChecks.contains("MiuiBackgroundPopupPolicy.miuiPermEditorIntent(context)"))

        // UI/UX Bureau (7199957531) & Arabic Bureau (7199958781) exact strings + EN/AR parity.
        assertTrue(enStrings.contains("Parents only see messages that look risky"))
        assertTrue(enStrings.contains("<string name=\"c05_roadmap_heading\">Next</string>"))
        assertTrue(enStrings.contains("<string name=\"c05_continue_to_pairing\">Continue</string>"))
        assertTrue(enStrings.contains("Done, let\\'s start"))
        assertTrue(arStrings.contains("اقرؤوا هذه القواعد معًا قبل البدء باستخدام هاتفك."))
        assertTrue(arStrings.contains("يمكن لأهلك مساعدتك في منح الأذونات."))
        assertTrue(arStrings.contains("لا شيء مخفي"))
        assertTrue(arStrings.contains("لا يطّلع أهلك إلا على الرسائل الخطرة، لا على كل محادثاتك."))

        val c05Keys = listOf(
            "c05_step_badge_1",
            "c05_step_badge_3",
            "c05_checks_title",
            "c05_checks_badge",
            "c05_checks_screen_time_title",
            "c05_checks_screen_time_subtitle",
            "c05_checks_location_title",
            "c05_checks_location_subtitle",
            "c05_checks_messages_title",
            "c05_checks_messages_subtitle",
            "c05_roadmap_heading",
            "c05_roadmap_step_1",
            "c05_roadmap_step_2",
            "c05_roadmap_step_3",
            "c05_welcome_footer_hint",
            "c05_continue_to_pairing",
            "c05_agreement_title",
            "c05_agreement_body",
            "c05_agreement_finish",
        )
        for (key in c05Keys) {
            assertTrue("EN strings missing $key", enStrings.contains("name=\"$key\""))
            assertTrue("AR strings missing $key", arStrings.contains("name=\"$key\""))
            val arLine = arStrings.lineSequence().firstOrNull { it.contains("name=\"$key\"") }.orEmpty()
            assertFalse("AR string $key must not contain Latin OSRA: $arLine", arLine.contains("OSRA"))
        }
    }

    private fun findAppSrcRoot(): File {
        var dir = File(System.getProperty("user.dir") ?: ".")
        repeat(5) {
            val candidate = File(dir, "src/main")
            if (candidate.isDirectory) return candidate
            val nested = File(dir, "app/src/main")
            if (nested.isDirectory) return nested
            dir = dir.parentFile ?: return candidate
        }
        return File("src/main")
    }
}
