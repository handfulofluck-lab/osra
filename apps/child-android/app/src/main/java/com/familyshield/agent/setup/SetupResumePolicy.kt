package com.familyshield.agent.setup

/** Which screen the pairing activity shows for a paired device. */
enum class PairedScreen { SET_PIN, STATUS }

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
}
