package com.familyshield.agent.security

import android.content.Context
import android.content.SharedPreferences
import android.util.Log
import androidx.security.crypto.EncryptedSharedPreferences
import androidx.security.crypto.MasterKey
import dagger.hilt.android.qualifiers.ApplicationContext
import javax.inject.Inject
import javax.inject.Singleton

/**
 * AES-256-GCM EncryptedSharedPreferences (ADR-0010) for the few values that are genuinely sensitive
 * on the device: the parent-PIN hash today, and — migrated in a follow-up — the device JWT and
 * per-device HMAC secret, which the audit found sitting in plaintext DataStore despite
 * `security-crypto` already being a dependency.
 *
 * If the keystore-backed store cannot be opened (a rare OEM keystore fault), we fall back to a plain
 * store rather than crash the agent: a readable PIN hash is still a salted PBKDF2 hash, not the PIN.
 */
@Singleton
class SecureStore @Inject constructor(
    @ApplicationContext private val context: Context,
) {
    private val prefs: SharedPreferences by lazy { open() }

    fun putString(key: String, value: String?) {
        prefs.edit().apply { if (value == null) remove(key) else putString(key, value) }.apply()
    }

    fun getString(key: String): String? = prefs.getString(key, null)

    private fun open(): SharedPreferences = try {
        val masterKey = MasterKey.Builder(context)
            .setKeyScheme(MasterKey.KeyScheme.AES256_GCM)
            .build()
        EncryptedSharedPreferences.create(
            context,
            "osra_secure_store",
            masterKey,
            EncryptedSharedPreferences.PrefKeyEncryptionScheme.AES256_SIV,
            EncryptedSharedPreferences.PrefValueEncryptionScheme.AES256_GCM,
        )
    } catch (e: Exception) {
        Log.e(TAG, "encrypted store unavailable; falling back to plain prefs", e)
        context.getSharedPreferences("osra_secure_store_fallback", Context.MODE_PRIVATE)
    }

    companion object {
        const val KEY_PARENT_PIN = "parent_pin_hash"

        private const val TAG = "SecureStore"
    }
}
