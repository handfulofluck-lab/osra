package com.familyshield.agent.telemetry

/**
 * #865 second half (Claude, 06:33Z): hands the applied rules version to the server as soon as the rules are
 * applied, instead of at the next telemetry tick.
 *
 * The Mac test bed measured the gap: rules reached v15 at 10:25:35, the phone acked the command at 10:26:24,
 * and `/v1/family/me` still said 14 six minutes later. The server's push (#865, #873) is correct — it
 * publishes the moment it hears the number — so the missing half was the phone never saying it: the version
 * travelled only in telemetry uploads, and the periodic upload returns early when there is no usage to send.
 *
 * The rule lives here, free of Android types, because the caller ([UsageReporter]) cannot run in a JVM test:
 * * report only on a change, against the version the **server accepted** rather than the one applied;
 * * record that version only after a 2xx, so a failed POST is retried on the next tick instead of being
 *   remembered as done.
 */
class AppliedRulesReporter(
    private val lastReported: suspend () -> Int?,
    private val recordReported: suspend (Int) -> Unit,
    private val upload: suspend (Int) -> Unit,
) {

    /**
     * Uploads [current] when the server does not already know it.
     *
     * @return true when an upload ran, false when there was nothing to say or the server already knew it.
     */
    suspend fun reportIfChanged(current: Int?): Boolean {
        // A phone that has never applied a ruleset has nothing to report; reporting 0 would be a claim.
        if (current == null) return false
        if (lastReported() == current) return false
        upload(current)
        recordReported(current)
        return true
    }
}
