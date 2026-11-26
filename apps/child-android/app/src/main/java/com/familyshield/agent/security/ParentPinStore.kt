package com.familyshield.agent.security

import javax.inject.Inject
import javax.inject.Singleton

/** Persists the salted parent-PIN hash in the encrypted store and answers verify/configured queries. */
@Singleton
class ParentPinStore @Inject constructor(
    private val secureStore: SecureStore,
) {
    /** True once a parent PIN has been set on this device. */
    fun isConfigured(): Boolean = !secureStore.getString(SecureStore.KEY_PARENT_PIN).isNullOrBlank()

    /**
     * osra-security#24 / #792 (Antigravity B2): a new PIN starts with no wrong-try debt. Left behind, a
     * count of eight from the previous PIN would lock the *new* one for an hour on the first typo.
     */
    /** Stores [pin] as a fresh PBKDF2 hash. Caller validates with [ParentPin.validationError] first. */
    fun set(pin: String) {
        secureStore.putString(SecureStore.KEY_PARENT_PIN, ParentPin.hash(pin))
        clearAttempts(secureStore)
    }

    /**
     * #1108: store a PIN set from the parent app, which arrives as the API-derived hash (Ahmed's R3, option A).
     *
     * Condition 6: the value must be exactly the shape [ParentPin.hash] writes ([ParentPin.isPrehashed]), or
     * nothing changes and the old PIN keeps working. The wrong-try debt is cleared only once the new value is
     * written **and read back**; a write that did not land leaves the old PIN and its count as they were.
     */
    fun setPrehashed(pinHash: String?): SetPrehashedResult {
        if (pinHash == null || !ParentPin.isPrehashed(pinHash)) return SetPrehashedResult.INVALID_SHAPE
        val previous = secureStore.getString(SecureStore.KEY_PARENT_PIN)
        runCatching { secureStore.putString(SecureStore.KEY_PARENT_PIN, pinHash) }
        val readBack = runCatching { secureStore.getString(SecureStore.KEY_PARENT_PIN) }.getOrNull()
        if (readBack != pinHash) {
            // Put back what was there, so a half-applied change can never lock the parent out.
            runCatching { secureStore.putString(SecureStore.KEY_PARENT_PIN, previous) }
            return SetPrehashedResult.WRITE_FAILED
        }
        clearAttempts(secureStore)
        return SetPrehashedResult.STORED
    }

    enum class SetPrehashedResult { STORED, INVALID_SHAPE, WRITE_FAILED }

    /**
     * Constant-time check of [pin] against the stored hash. A PIN stored before #771 from an Arabic
     * keyboard still opens, and is re-hashed in its normalised form the first time it does.
     */
    fun verify(pin: String): Boolean {
        val stored = secureStore.getString(SecureStore.KEY_PARENT_PIN)
        val match = ParentPin.verifyMatch(pin, stored)
        ParentPin.upgradedStoredHashOnUse(match, pin)?.let { upgraded ->
            runCatching { secureStore.putString(SecureStore.KEY_PARENT_PIN, upgraded) }
        }
        return match != ParentPin.Match.NONE
    }

    /** Clears the PIN (used only when the server authorises an unpair), and the debt that belonged to it. */
    fun clear() {
        secureStore.putString(SecureStore.KEY_PARENT_PIN, null)
        clearAttempts(secureStore)
    }

    /**
     * #792 (Antigravity B2): the keys [PinAttemptStore] owns, cleared here without taking a dependency on the
     * injected store — this class may be needed before Hilt is up (the gate opens from a service).
     */
    private fun clearAttempts(store: SecureStore) {
        store.putString(PinAttemptStore.KEY_FAILURES, null)
        store.putString(PinAttemptStore.KEY_LAST_FAILURE, null)
        store.putString(PinAttemptStore.KEY_LAST_FAILURE_ELAPSED, null)
        store.putString(PinAttemptStore.KEY_LAST_FAILURE_BOOT, null)
        store.putString(PinAttemptStore.KEY_ALERTED_AT, null)
    }
}
