package com.familyshield.agent.comms

/**
 * Issue #257 review: when a consent withdrawal must restart the comms watermarks, and from when.
 *
 * The reset used to be driven by a marker that only a harvest could write, and a harvest never runs
 * while consent is paused — so a pause shorter than the 5-minute loop was never recorded, and the
 * paused-window rows were read after the re-grant. Then the reset ran at the first harvest *after* the
 * re-grant, which stored "now" and read nothing, dropping the call that triggered it.
 *
 * The transition is now counted where the flag flips ([com.familyshield.agent.data.ConsentState]), and
 * the restart point is the moment the phone learned consent came back. This policy is the decision
 * table: pure, so the four cases below are a JVM test rather than a phone-only observation.
 */
object CommsConsentPolicy {

    /**
     * The timestamp every comms watermark restarts from, or null to leave them alone.
     *
     * @param storedEpoch the epoch last applied to the watermarks (null when never applied)
     * @param epoch the current [ConsentState][com.familyshield.agent.data.ConsentState] epoch
     * @param paused true while consent is withdrawn — a paused device collects nothing, so the reset
     *   waits for the re-grant rather than restarting into a paused window
     * @param resumedAtMs when the phone learned consent came back
     */
    fun resetTo(storedEpoch: Long?, epoch: Long, paused: Boolean, resumedAtMs: Long): Long? {
        if (paused) return null
        if (storedEpoch == epoch) return null
        // Never withdrawn (first run, or an upgrade from a build that had no epoch): nothing to reset,
        // and creating a watermark here would be the history import #229 exists to prevent.
        if (storedEpoch == null && epoch == 0L) return null
        // Restart where the phone learned about the re-grant, not "now": a call made a moment after the
        // re-grant must still be read, and resumedAtMs is <= now.
        return resumedAtMs
    }
}
