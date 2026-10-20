package com.familyshield.agent.telemetry

/**
 * Issue #221 (D1 follow-up, Claude's review of #228): sends the location grant as soon as it changes
 * instead of waiting for the 15-minute telemetry tick.
 *
 * Without this the server knows the grant only from the last periodic upload, so a child who grants
 * "Allow all the time" can still be refused a Locate for up to fifteen minutes — Claude measured
 * exactly that on the Flip4: grant, then Locate four seconds later, refused. The server's freshness
 * guard (`LOCATION_GRANT_MAX_AGE_MS`) stops the refusal getting worse; this stops it happening at
 * all on a handset that is awake.
 *
 * The rule lives here, free of Android types, because the caller (`UsageReporter`) cannot run in a
 * JVM test: report only on a change, and record the reported value only after the upload returns, so
 * a failed request is retried by the next resume rather than silently forgotten.
 */
class LocationGrantReporter(
    private val lastReported: suspend () -> String?,
    private val recordReported: suspend (String) -> Unit,
    private val upload: suspend (String) -> Unit,
) {

    /**
     * Sends [current] when it differs from the last reported grant.
     *
     * @return true when an upload ran, false when the server already knows this value.
     */
    suspend fun reportIfChanged(current: String): Boolean {
        if (lastReported() == current) return false
        upload(current)
        recordReported(current)
        return true
    }
}
