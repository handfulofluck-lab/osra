package com.familyshield.agent.setup

/** Unpaired first-run onboarding stage for C-05 + #1174 (permissions before pairing). */
enum class PrePairStage {
    WELCOME,
    PRE_PAIR_PERMISSIONS,
    PRE_PAIR_CHECKLIST,
    PAIRING_FORM,
}

/**
 * Issue #1174 & C-05 First run (#1179):
 * 1. Required permissions (`OnboardingPolicy.canComplete(rows)`) run **before** the pairing code
 *    step so rules cannot start blocking setup screens mid-onboarding (e.g. Redmi Xiaomi Security).
 * 2. Even if a phone was paired early or a required grant is later lost, app-block / routine
 *    enforcement is suppressed until all required grants are complete.
 * 3. Every resume re-evaluates live grants and advances automatically to pairing once ready.
 */
object FirstRunOrderPolicy {

    fun resolveUnpairedStage(
        welcomeCompleted: Boolean,
        requiredGrantsReady: Boolean,
        forceChecklist: Boolean,
        hasTypedOrScannedPairing: Boolean,
        c05Enabled: Boolean = true,
    ): PrePairStage {
        if (hasTypedOrScannedPairing) return PrePairStage.PAIRING_FORM
        if (!welcomeCompleted) return PrePairStage.WELCOME
        if (!c05Enabled || requiredGrantsReady) return PrePairStage.PAIRING_FORM
        return if (forceChecklist) PrePairStage.PRE_PAIR_CHECKLIST else PrePairStage.PRE_PAIR_PERMISSIONS
    }

    /**
     * Issue #1174 requirement #2: never enforce app blocks or routines on a paired phone whose
     * required onboarding grants are not yet complete.
     */
    fun shouldSuppressEnforcement(
        paired: Boolean,
        requiredGrantsReady: Boolean,
    ): Boolean = paired && !requiredGrantsReady
}
