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
class UnlinkPolicy(
    private val confirmAfterMs: Long = DEFAULT_CONFIRM_MS,
    /**
     * Issue #1073: a stored first answer older than this is treated as absent. Persistence must never let an
     * old answer count as half of a new pair — that is the reason the rule wants two answers at all (Ahmed's
     * security condition on this issue).
     */
    private val staleAfterMs: Long = DEFAULT_STALE_MS,
    nowMs: Long = System.currentTimeMillis(),
    persistedFirstRevokedAtMs: Long? = null,
    /** Writes the pending timestamp (or null when it is cleared); a no-op keeps the JVM rows pure. */
    private val persist: (Long?) -> Unit = {},
) {

    private var firstRevokedAtMs: Long? = null
    private var unlinked = false

    init {
        val stored = persistedFirstRevokedAtMs
        if (stored != null) {
            val age = nowMs - stored
            // Fresh enough to mean something: adopt. Otherwise drop it on disk rather than carry a stale clock.
            if (age in 0..staleAfterMs) firstRevokedAtMs = stored else persist(null)
        }
    }

    /**
     * One `device_revoked` answer. Returns true when the unlink is now **confirmed** — the second answer,
     * at least [confirmAfterMs] after the first. A second answer arriving sooner than that is not a
     * confirmation; it is the same event being retried, and it keeps the original timestamp so a flapping
     * server cannot keep the phone linked by answering twice quickly.
     */
    fun onDeviceRevoked(nowMs: Long): Boolean {
        if (unlinked) return true
        val first = firstRevokedAtMs
        // #1162 (Ahmed): the window is enforced in memory too, not only at construction. A phone that stays up
        // for hours must not confirm on an answer it received before the window.
        if (first == null || nowMs - first > staleAfterMs) {
            firstRevokedAtMs = nowMs
            persist(nowMs)
            return false
        }
        if (nowMs - first < confirmAfterMs) return false
        unlinked = true
        persist(null) // the unlink is done; the stored clock has no further use
        return true
    }

    /** A successful call: the phone is still linked, so any half-confirmation is dropped. */
    fun onLinked() {
        if (unlinked) return
        firstRevokedAtMs = null
        persist(null)
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

        /** How old a persisted first answer may be and still count (#1073, Ahmed's ~10 minutes). */
        const val DEFAULT_STALE_MS: Long = 600_000L
    }
}
