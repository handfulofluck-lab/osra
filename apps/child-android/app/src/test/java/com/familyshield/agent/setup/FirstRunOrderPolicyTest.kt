package com.familyshield.agent.setup

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File

/**
 * C-05 First run (#1179) + #1174 (permissions before pairing, no enforcement until required grants
 * are complete, no Skip on required grants, live grant re-read on resume) + U74 fix 1 ("Open app
 * info" straight after step 1 of the #1176 restricted-settings guide).
 *
 * Mutants:
 * - Return PAIRING_FORM before requiredGrantsReady -> pre-pair permissions test goes red.
 * - Return false from shouldSuppressEnforcement while required grants incomplete -> enforcement gate test goes red.
 * - Move onOpenAppInfo back below step 2 -> U74 ordering test goes red.
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
    fun `enforcement is suppressed while paired phone still lacks required grants`() {
        assertTrue(FirstRunOrderPolicy.shouldSuppressEnforcement(paired = true, requiredGrantsReady = false))
        assertFalse(FirstRunOrderPolicy.shouldSuppressEnforcement(paired = true, requiredGrantsReady = true))
        assertFalse(FirstRunOrderPolicy.shouldSuppressEnforcement(paired = false, requiredGrantsReady = false))
        assertFalse(FirstRunOrderPolicy.shouldSuppressEnforcement(paired = false, requiredGrantsReady = true))
    }

    @Test
    fun `wiring enforces U74 button placement, #1174 suppression, agreement-last screen, and EN-AR copy`() {
        val root = findAppSrcRoot()
        val screens = File(root, "java/com/familyshield/agent/ui/pairing/OnboardingWelcomeAndStepsScreen.kt").readText()
        val activity = File(root, "java/com/familyshield/agent/setup/PairingActivity.kt").readText()
        val service = File(root, "java/com/familyshield/agent/services/AccessibilityMonitorService.kt").readText()
        val enStrings = File(root, "res/values/strings.xml").readText()
        val arStrings = File(root, "res/values-ar/strings.xml").readText()

        // U74 fix 1: Open app info button sits inside the step loop right after step 1 (index == 0).
        val stepLoopIdx = screens.indexOf("guide.steps.forEachIndexed")
        val openAppInfoIdx = screens.indexOf("index == 0 && onOpenAppInfo != null")
        val waitingLineIdx = screens.indexOf("guide.waitingLine")
        assertTrue("U74 button condition missing", openAppInfoIdx > stepLoopIdx && openAppInfoIdx < waitingLineIdx)
        assertTrue("Agreement-last composable missing", screens.contains("fun OnboardingFamilyAgreementScreen("))
        assertTrue("Transparency card composable missing", screens.contains("private fun OsraTransparencyCard("))

        // #1174: PairingActivity routes unpaired flow through FirstRunOrderPolicy, re-reads grants on resume,
        // and renders agreement-last in showComplete. (#1175 no-skip on Device Admin stays with PR #1198.)
        assertTrue(activity.contains("FirstRunOrderPolicy.resolveUnpairedStage("))
        assertTrue(activity.contains("OnboardingFamilyAgreementScreen("))
        assertTrue(activity.contains("ChildUxFlags.c05FirstRunEnabled"))

        // #1174 requirement #2: AccessibilityMonitorService suppresses enforcement when required grants are incomplete.
        assertTrue(service.contains("FirstRunOrderPolicy.shouldSuppressEnforcement("))
        assertTrue(service.contains("requiredGrantsIncompleteForPairedDevice()"))

        // EN + AR string parity for all C-05 keys, with no Latin OSRA leaked into Arabic C-05 strings.
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
