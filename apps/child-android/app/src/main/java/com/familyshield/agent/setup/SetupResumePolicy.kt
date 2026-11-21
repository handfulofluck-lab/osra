package com.familyshield.agent.setup

/** Which screen the pairing activity shows for a paired device. */
enum class PairedScreen { SET_PIN, STATUS }

/**
 * Guided post-pairing onboarding stage (`#966` review follow-up).
 *
 * Pairing is saved before the PIN and guided permissions run, so an activity recreation or a
 * return from an OS permission prompt / Settings screen must preserve the active stage until the
 * parent reaches explicit completion.
 */
enum class GuidedStage {
    SET_PIN,
    PROTECTION_SETUP,
    STALE_KNOX_ADMIN,
    PERMISSION_STEP,
    CHECKLIST,
    COMPLETE,
    STATUS,
}

/** Explicit Back navigation action for the active guided stage. */
enum class BackAction {
    TO_PERMISSION_STEP,
    TO_PROTECTION_SETUP,
    TO_STATUS,
    SYSTEM_DEFAULT,
}

/**
 * ADR-0010 §2: "Before a PIN exists nothing is gated — pairing sets one, so that window is the setup
 * screen only." The PIN step was shown once, right after the claim was approved; a relaunch at that
 * moment (the #440 Flip4 run: the tester switched apps to tap Allow) went to the status screen, where
 * Set parent PIN was an optional button and every guarded action ran without a PIN.
 *
 * A paired device with no PIN therefore always resumes on the PIN step, so the ungated window stays
 * the setup screen, as the ADR says. Who sets the PIN is unchanged: whoever holds the phone at pairing.
 */
object SetupResumePolicy {
    fun pairedScreen(pinConfigured: Boolean): PairedScreen =
        if (pinConfigured) PairedScreen.STATUS else PairedScreen.SET_PIN

    /**
     * Resolves the paired stage on launch or recreation: missing PIN forces [GuidedStage.SET_PIN],
     * an in-progress [activeStage] stays active, and an already-completed paired launch opens [GuidedStage.STATUS].
     */
    fun resolvePairedStage(pinConfigured: Boolean, activeStage: GuidedStage?): GuidedStage {
        if (!pinConfigured) return GuidedStage.SET_PIN
        return activeStage ?: GuidedStage.STATUS
    }

    /**
     * Computes the stage after returning from an OS permission prompt, admin sheet, or Settings
     * screen (`onResume` or `ActivityResultLauncher`) so an in-progress guided flow advances cleanly
     * without prematurely dropping back to [GuidedStage.STATUS].
     */
    fun stageAfterPermissionReturn(
        pinConfigured: Boolean,
        currentStage: GuidedStage?,
        isAdminActive: Boolean,
        staleKnox: Boolean,
        canComplete: Boolean,
        forceChecklist: Boolean,
    ): GuidedStage {
        if (!pinConfigured) return GuidedStage.SET_PIN
        if (staleKnox) return GuidedStage.STALE_KNOX_ADMIN
        return when (currentStage) {
            GuidedStage.SET_PIN -> GuidedStage.SET_PIN
            GuidedStage.PROTECTION_SETUP, GuidedStage.STALE_KNOX_ADMIN -> {
                if (isAdminActive) {
                    guidedPostProtectionStage(canComplete = canComplete, forceChecklist = forceChecklist)
                } else {
                    currentStage
                }
            }
            GuidedStage.PERMISSION_STEP -> if (canComplete) GuidedStage.COMPLETE else GuidedStage.PERMISSION_STEP
            GuidedStage.CHECKLIST -> GuidedStage.CHECKLIST
            GuidedStage.COMPLETE -> GuidedStage.COMPLETE
            GuidedStage.STATUS, null -> GuidedStage.STATUS
        }
    }

    fun guidedPostProtectionStage(canComplete: Boolean, forceChecklist: Boolean): GuidedStage = when {
        canComplete -> GuidedStage.COMPLETE
        forceChecklist -> GuidedStage.CHECKLIST
        else -> GuidedStage.PERMISSION_STEP
    }

    /** Explicit Back behavior for guided onboarding stages. */
    fun backAction(stage: GuidedStage?, firstRun: Boolean): BackAction = when (stage) {
        GuidedStage.CHECKLIST -> if (firstRun) BackAction.TO_PERMISSION_STEP else BackAction.TO_STATUS
        GuidedStage.PERMISSION_STEP, GuidedStage.COMPLETE ->
            if (!firstRun) BackAction.TO_STATUS else BackAction.SYSTEM_DEFAULT
        GuidedStage.STALE_KNOX_ADMIN -> BackAction.TO_PROTECTION_SETUP
        else -> BackAction.SYSTEM_DEFAULT
    }
}
