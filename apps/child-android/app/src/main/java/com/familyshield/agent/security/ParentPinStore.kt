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
