package com.familyshield.agent.security

import javax.inject.Inject
import javax.inject.Singleton

/**
 * osra-security#24: where the wrong-PIN count lives, so reopening the screen does not reset it.
 *
 * The count, the time of the last failure and the failure count the parent was last alerted for go into
 * the encrypted store, next to the PIN hash itself — the same places that survive a process death and the
 * activity being recreated. Nothing new is written in plaintext, and nothing here is a secret: three
 * integers.
 *
 * The storage is behind [PinAttemptStorage] rather than taken as a `SecureStore` so a JVM test can hand it
 * an in-memory map and show that two consecutive [PinAttemptStore] instances — that is, two activity
 * instances — read the same count. That is the survival row [PinLockout] cannot write on its own.
 */
interface PinAttemptStorage {
    fun get(key: String): String?
    fun put(key: String, value: String?)
}

@Singleton
class PinAttemptStore @Inject constructor(
    private val storage: PinAttemptStorage,
) {

    /** The persisted state; a missing or unreadable value reads as "no failures", which cannot lock. */
    fun read(): PinLockout.State = PinLockout.State(
        failures = storage.get(KEY_FAILURES)?.toIntOrNull()?.coerceAtLeast(0) ?: 0,
        lastFailureMs = storage.get(KEY_LAST_FAILURE)?.toLongOrNull()?.coerceAtLeast(0L) ?: 0L,
        alertedAt = storage.get(KEY_ALERTED_AT)?.toIntOrNull()?.coerceAtLeast(0) ?: 0,
    )

    fun write(state: PinLockout.State) {
        storage.put(KEY_FAILURES, state.failures.toString())
        storage.put(KEY_LAST_FAILURE, state.lastFailureMs.toString())
        storage.put(KEY_ALERTED_AT, state.alertedAt.toString())
    }

    /** After a correct PIN: the count goes back to zero, which is the only thing that resets it. */
    fun clear() {
        storage.put(KEY_FAILURES, null)
        storage.put(KEY_LAST_FAILURE, null)
        storage.put(KEY_ALERTED_AT, null)
    }

    companion object {
        const val KEY_FAILURES = "parent_pin_failures"
        const val KEY_LAST_FAILURE = "parent_pin_last_failure_ms"
        const val KEY_ALERTED_AT = "parent_pin_alerted_at"
    }
}
