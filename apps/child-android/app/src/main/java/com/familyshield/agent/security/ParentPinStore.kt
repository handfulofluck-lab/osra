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

    /** Stores [pin] as a fresh PBKDF2 hash. Caller validates with [ParentPin.validationError] first. */
    fun set(pin: String) {
        secureStore.putString(SecureStore.KEY_PARENT_PIN, ParentPin.hash(pin))
    }

    /** Constant-time check of [pin] against the stored hash. */
    fun verify(pin: String): Boolean =
        ParentPin.verify(pin, secureStore.getString(SecureStore.KEY_PARENT_PIN))

    /** Clears the PIN (used only when the server authorises an unpair). */
    fun clear() {
        secureStore.putString(SecureStore.KEY_PARENT_PIN, null)
    }
}
