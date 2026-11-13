package com.familyshield.agent.security

/**
 * osra-security#8 F2 follow-up: the secure pairing writes, free of Android types so the failure modes are JVM-testable.
 * Every write is verified by reading it back before the caller may touch plaintext storage or in-memory caches — a
 * fail-closed store drops a write silently, so "returned without throwing" is not "persisted".
 */
class SecureStoreWriter(
    private val unreadable: () -> Boolean,
    private val putString: (String, String?) -> Unit,
    private val getString: (String) -> String?,
) {

    /**
     * Persists [tokenKey]=[deviceJwt] (and [hmacKey] when [hmacSecret] is not null), then verifies both read back.
     * @return true only when every written secret persisted; false when the store is unreadable or any write was
     * dropped — in which case the caller must not record the pairing anywhere (no caches, no plaintext DataStore row).
     */
    fun writePairing(tokenKey: String, deviceJwt: String, hmacKey: String, hmacSecret: String?): Boolean {
        if (unreadable()) return false
        putString(tokenKey, deviceJwt)
        if (hmacSecret != null) putString(hmacKey, hmacSecret)
        if (getString(tokenKey) != deviceJwt) return false
        return hmacSecret == null || getString(hmacKey) == hmacSecret
    }

    /**
     * Moves a legacy plaintext [value] into the secure store. @return the value only when it now reads back from the
     * secure store; null when the store is unreadable or the write was dropped — the caller must then keep the
     * plaintext copy rather than deleting the only credential it holds.
     */
    fun migrate(secureKey: String, value: String): String? {
        if (unreadable()) return null
        putString(secureKey, value)
        return if (getString(secureKey) == value) value else null
    }
}
