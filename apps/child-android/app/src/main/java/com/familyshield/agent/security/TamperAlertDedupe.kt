package com.familyshield.agent.security

/**
 * Idempotency key for the device-admin-removed alert (issue #225).
 *
 * One deactivation used to page the parent twice: the expedited worker enqueued by
 * [GuardianAdminReceiver.onDisabled] posted, and the 60-s drain in `LocationService` enqueued the
 * same work again when it saw the still-pending flag or the tier drop. The key names the event —
 * device, alert type and the disable timestamp recorded in `onDisabled` — so both paths compute the
 * same value and the second POST is skipped. The server's partial unique index on
 * `(deviceId, category, dedupeKey)` is the backstop when the two workers race.
 */
object TamperAlertDedupe {

    /** The disable timestamp is 0 only for a tier drop observed without `onDisabled`; the drain sets it. */
    fun adminRemovalKey(deviceId: String?, disabledAtMs: Long): String =
        "${deviceId ?: "unknown"}|${TamperAlertWorker.TYPE_ADMIN_REMOVED}|$disabledAtMs"

    /**
     * Issue #227: the identity of one remove-protection **window**, not one attempt. The server
     * updates this row's count when a later attempt in the same window repeats the key; the count is
     * data on the key, so putting it in the key would create a row per attempt again.
     */
    fun guardAggregateKey(deviceId: String?, windowStartMs: Long): String =
        "${deviceId ?: "unknown"}|${TamperAlertWorker.TYPE_GUARD_TRIGGERED}|$windowStartMs"

    /**
     * The client-side "already posted" key for one count inside the window. It includes the count so
     * a higher count posts to the same server row, while a WorkManager retry of the **same** work
     * (lost response) is a no-op. Recorded only after the POST returns, as [TamperAlertDispatcher]
     * requires.
     */
    fun guardPostKey(deviceId: String?, window: GuardAttemptWindow.State): String =
        "${guardAggregateKey(deviceId, window.windowStartMs)}|${window.count}"
}

/**
 * Runs [post] at most once per dedupe key. A key already recorded short-circuits before the POST;
 * if [post] throws, the key is not recorded, so the caller's retry still tries again.
 *
 * The rule lives here, free of Android types, because the worker itself cannot run in a JVM test.
 */
class TamperAlertDispatcher(
    private val wasPosted: (String) -> Boolean,
    private val recordPosted: (String) -> Unit,
) {

    /** @return true when [post] ran, false when this key was already posted. */
    /** @return true when [post] ran, false when this key was already posted. */
    suspend fun dispatch(dedupeKey: String?, post: suspend () -> Unit): Boolean {
        if (dedupeKey != null && wasPosted(dedupeKey)) return false
        // The key is recorded only after the POST returns: a failure must leave the retry possible.
        post()
        if (dedupeKey != null) recordPosted(dedupeKey)
        return true
    }
}
