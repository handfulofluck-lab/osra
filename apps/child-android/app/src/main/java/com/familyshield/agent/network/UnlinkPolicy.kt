package com.familyshield.agent.network

/**
 * Issue #465: when a `device_revoked` answer is acted on, and when it is not.
 *
 * **Two answers, at least [confirmAfterMs] apart.** A single `401 device_revoked` could be a server bug,
 * a half-applied deploy, or a request answered by the wrong database. Unlinking on one answer would
 * switch off a child's protection for a reason nobody intended, and the phone cannot be re-paired
 * without a parent who may no longer exist. So the policy asks for the same answer twice.
 *
 * **Any `200` in between resets it.** A poll that succeeds proves the phone is still linked; the count
 * starts again rather than carrying a stale half-confirmation.
 *
 * Pure, clock-injected, no Android types: the JVM suite pins every row (U1–U4).
 */
class UnlinkPolicy(private val confirmAfterMs: Long = DEFAULT_CONFIRM_MS) {

    private var firstRevokedAtMs: Long? = null
    private var unlinked = false

    /**
     * One `device_revoked` answer. Returns true when the unlink is now **confirmed** — the second answer,
     * at least [confirmAfterMs] after the first. A second answer arriving sooner than that is not a
     * confirmation; it is the same event being retried, and it keeps the original timestamp so a flapping
     * server cannot keep the phone linked by answering twice quickly.
     */
    fun onDeviceRevoked(nowMs: Long): Boolean {
        if (unlinked) return true
        val first = firstRevokedAtMs
        if (first == null) {
            firstRevokedAtMs = nowMs
            return false
        }
        if (nowMs - first < confirmAfterMs) return false
        unlinked = true
        return true
    }

    /** A successful call: the phone is still linked, so any half-confirmation is dropped. */
    fun onLinked() {
        if (unlinked) return
        firstRevokedAtMs = null
    }

    /** True once the unlink is confirmed: nothing may enforce, and no further poll is made. */
    fun isUnlinked(): Boolean = unlinked

    /** Whether the poller should still talk to the server. */
    fun shouldPoll(): Boolean = !unlinked

    /** How long until the pending answer would become a confirmation, or null when none is pending. */
    fun pendingSinceMs(): Long? = firstRevokedAtMs

    companion object {
        /** The issue's interval: two answers at least a minute apart. */
        const val DEFAULT_CONFIRM_MS: Long = 60_000L
    }
}
