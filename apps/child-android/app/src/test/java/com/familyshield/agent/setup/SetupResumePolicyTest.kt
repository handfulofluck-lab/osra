package com.familyshield.agent.setup

import java.io.File
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * ADR-0010 §2 & #966 guided-setup lifecycle policy tests:
 * - paired device with no PIN always resumes on [GuidedStage.SET_PIN] / [PairedScreen.SET_PIN];
 * - active guided setup stage survives recreation and OS permission prompt returns;
 * - status screen is entered on explicit completion or fresh already-completed launch;
 * - Back navigation across guided stages is explicit.
 */
class SetupResumePolicyTest {

    @Test
    fun `a paired device with no PIN resumes on the PIN step`() {
        assertEquals(PairedScreen.SET_PIN, SetupResumePolicy.pairedScreen(pinConfigured = false))
        assertEquals(
            GuidedStage.SET_PIN,
            SetupResumePolicy.resolvePairedStage(pinConfigured = false, activeStage = GuidedStage.PERMISSION_STEP),
        )
    }

    @Test
    fun `a paired device with a PIN shows the status screen when no guided stage is active`() {
        assertEquals(PairedScreen.STATUS, SetupResumePolicy.pairedScreen(pinConfigured = true))
        assertEquals(
            GuidedStage.STATUS,
            SetupResumePolicy.resolvePairedStage(pinConfigured = true, activeStage = null),
        )
    }

    @Test
    fun `paired device preserves active guided stage across activity recreation`() {
        for (stage in listOf(
            GuidedStage.PROTECTION_SETUP,
            GuidedStage.STALE_KNOX_ADMIN,
            GuidedStage.PERMISSION_STEP,
            GuidedStage.CHECKLIST,
            GuidedStage.COMPLETE,
        )) {
            assertEquals(
                "Stage $stage must survive recreation while paired",
                stage,
                SetupResumePolicy.resolvePairedStage(pinConfigured = true, activeStage = stage),
            )
        }
    }

    @Test
    fun `returning from OS permission grant or Settings preserves guided flow until explicit completion`() {
        // Cancelling Device Admin during protection setup stays on PROTECTION_SETUP (never jumps to STATUS).
        assertEquals(
            GuidedStage.PROTECTION_SETUP,
            SetupResumePolicy.stageAfterPermissionReturn(
                pinConfigured = true,
                currentStage = GuidedStage.PROTECTION_SETUP,
                isAdminActive = false,
                staleKnox = false,
                canComplete = false,
                forceChecklist = false,
            ),
        )

        // Granting Device Admin during protection setup advances into the guided permission steps.
        assertEquals(
            GuidedStage.PERMISSION_STEP,
            SetupResumePolicy.stageAfterPermissionReturn(
                pinConfigured = true,
                currentStage = GuidedStage.PROTECTION_SETUP,
                isAdminActive = true,
                staleKnox = false,
                canComplete = false,
                forceChecklist = false,
            ),
        )

        // Returning after granting one permission while more required permissions remain stays on PERMISSION_STEP.
        assertEquals(
            GuidedStage.PERMISSION_STEP,
            SetupResumePolicy.stageAfterPermissionReturn(
                pinConfigured = true,
                currentStage = GuidedStage.PERMISSION_STEP,
                isAdminActive = true,
                staleKnox = false,
                canComplete = false,
                forceChecklist = false,
            ),
        )

        // Returning with the final required permission granted advances to COMPLETE (waiting for explicit Open Status).
        assertEquals(
            GuidedStage.COMPLETE,
            SetupResumePolicy.stageAfterPermissionReturn(
                pinConfigured = true,
                currentStage = GuidedStage.PERMISSION_STEP,
                isAdminActive = true,
                staleKnox = false,
                canComplete = true,
                forceChecklist = false,
            ),
        )

        // Returning from a grant opened from the checklist keeps CHECKLIST active.
        assertEquals(
            GuidedStage.CHECKLIST,
            SetupResumePolicy.stageAfterPermissionReturn(
                pinConfigured = true,
                currentStage = GuidedStage.CHECKLIST,
                isAdminActive = true,
                staleKnox = false,
                canComplete = false,
                forceChecklist = true,
            ),
        )

        // Explicit completion enters STATUS and stays on STATUS for subsequent reconnects.
        assertEquals(
            GuidedStage.STATUS,
            SetupResumePolicy.resolvePairedStage(pinConfigured = true, activeStage = GuidedStage.STATUS),
        )
    }

    @Test
    fun `guided Back behavior is explicit per stage`() {
        assertEquals(
            BackAction.TO_PERMISSION_STEP,
            SetupResumePolicy.backAction(GuidedStage.CHECKLIST, firstRun = true, hasRemainingStep = true),
        )
        // All grants complete on first-run checklist leaves Done as explicit completion and uses normal Back.
        assertEquals(
            BackAction.SYSTEM_DEFAULT,
            SetupResumePolicy.backAction(GuidedStage.CHECKLIST, firstRun = true, hasRemainingStep = false),
        )
        assertEquals(BackAction.TO_STATUS, SetupResumePolicy.backAction(GuidedStage.CHECKLIST, firstRun = false))
        assertEquals(BackAction.TO_STATUS, SetupResumePolicy.backAction(GuidedStage.PERMISSION_STEP, firstRun = false))
        assertEquals(BackAction.TO_PROTECTION_SETUP, SetupResumePolicy.backAction(GuidedStage.STALE_KNOX_ADMIN, firstRun = true))
        assertEquals(BackAction.SYSTEM_DEFAULT, SetupResumePolicy.backAction(GuidedStage.PERMISSION_STEP, firstRun = true))
        assertEquals(BackAction.SYSTEM_DEFAULT, SetupResumePolicy.backAction(GuidedStage.STATUS, firstRun = true))
    }

    @Test
    fun `PairingActivity routes paired resume and recreation through SetupResumePolicy`() {
        val text = loadPairingActivitySource()
        val body = text.substringAfter("private fun showStatus() {").lineSequence().drop(1).take(4).joinToString("\n")
        assertTrue("showStatus must start with the PIN gate:\n$body", body.contains("SetupResumePolicy.pairedScreen(pinStore.isConfigured()) == PairedScreen.SET_PIN"))
        assertTrue(body.contains("showSetPin()"))
        assertTrue("onCreate must restore active guided stage via resolvePairedStage", text.contains("SetupResumePolicy.resolvePairedStage(pinStore.isConfigured(), activeGuidedStage)"))
        assertTrue("permission returns must flow through stageAfterPermissionReturn", text.contains("SetupResumePolicy.stageAfterPermissionReturn("))
        assertTrue("explicit completion button must move to status via finishGuidedSetupAndShowStatus", text.contains("setOnClickListener { finishGuidedSetupAndShowStatus() }"))
        assertTrue("Back behavior must dispatch through SetupResumePolicy.backAction with hasRemainingStep", text.contains("SetupResumePolicy.backAction(activeGuidedStage, guidedFirstRun, hasRemainingStep)"))
    }

    private fun loadPairingActivitySource(): String {
        var dir: File? = File(System.getProperty("user.dir") ?: ".").absoluteFile
        while (dir != null) {
            val candidate = File(dir, "app/src/main/java/com/familyshield/agent/setup/PairingActivity.kt")
            if (candidate.isFile) return candidate.readText()
            dir = dir.parentFile
        }
        error("PairingActivity.kt not found")
    }
}
