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
 * AES-256-GCM EncryptedSharedPreferences (ADR-0010) for the values that are genuinely sensitive on the device: the
 * parent-PIN hash, the device JWT and the per-device HMAC secret.
 *
 * osra-security#8 F2: opening used to fall back to plain prefs on **any** failure, silently. A restored backup is one
 * such failure (the file comes back, its Keystore key does not), and the agent then read every secret as missing and
 * wrote new ones in plaintext. Now ([SecureStoreOpening]):
 * 1. the encrypted store opens: use it, and move anything an older build left in the plaintext fallback into it, then
 *    delete that file;
 * 2. it fails twice in a row (once could be a passing Keystore hiccup, which must not cost the pairing): the encrypted
 *    file is unreadable, so it is deleted and opened fresh. The phone reads as unpaired and re-pairs; nothing is
 *    written in plaintext;
 * 3. it still does not (the Keystore itself is broken on this phone): only then the plaintext fallback, logged as an
 *    error and recorded in [degraded], so the phone can still stay paired. A salted PBKDF2 hash is not the PIN.
 */
@Singleton
class SecureStore @Inject constructor(
    @ApplicationContext private val context: Context,
) {
    private val prefs: SharedPreferences by lazy { open() }

    /** True when this phone's Keystore could not open the encrypted store at all (step 3). */
    @Volatile var degraded: Boolean = false
        private set

    fun putString(key: String, value: String?) {
        prefs.edit().apply { if (value == null) remove(key) else putString(key, value) }.apply()
    }

    fun getString(key: String): String? = prefs.getString(key, null)

    private fun open(): SharedPreferences {
        val first = runCatching { encrypted() }.let { if (it.isSuccess) it else runCatching { encrypted() } }
        val retry = if (first.isSuccess) null else {
            Log.e(TAG, "encrypted store unreadable; deleting it and opening it fresh", first.exceptionOrNull())
            context.deleteSharedPreferences(FILE)
            runCatching { encrypted() }
        }
        return when (SecureStoreOpening.decide(firstOpened = first.isSuccess, retryOpened = retry?.isSuccess == true)) {
            SecureStoreOpening.Outcome.ENCRYPTED -> first.getOrThrow().also(::adoptPlaintextFallback)
            SecureStoreOpening.Outcome.RESET_ENCRYPTED -> retry!!.getOrThrow().also(::dropPlaintextFallback)
            SecureStoreOpening.Outcome.PLAINTEXT_DEGRADED -> {
                Log.e(TAG, "Keystore cannot open an encrypted store on this phone; using the plaintext fallback",
                    retry?.exceptionOrNull())
                degraded = true
                context.getSharedPreferences(FALLBACK_FILE, Context.MODE_PRIVATE)
            }
        }
    }

    private fun encrypted(): SharedPreferences {
        val masterKey = MasterKey.Builder(context)
            .setKeyScheme(MasterKey.KeyScheme.AES256_GCM)
            .build()
        return EncryptedSharedPreferences.create(
            context,
            FILE,
            masterKey,
            EncryptedSharedPreferences.PrefKeyEncryptionScheme.AES256_SIV,
            EncryptedSharedPreferences.PrefValueEncryptionScheme.AES256_GCM,
        )
    }

    /** An older build may have written secrets in plaintext; they move into the encrypted store, then the file goes. */
    private fun adoptPlaintextFallback(target: SharedPreferences) {
        val plain = context.getSharedPreferences(FALLBACK_FILE, Context.MODE_PRIVATE)
        val leftovers = plain.all.filterValues { it is String }
        if (leftovers.isNotEmpty()) {
            target.edit().apply { leftovers.forEach { (k, v) -> if (!target.contains(k)) putString(k, v as String) } }.commit()
        }
        dropPlaintextFallback(target)
    }

    @Suppress("UNUSED_PARAMETER")
    private fun dropPlaintextFallback(target: SharedPreferences) {
        context.deleteSharedPreferences(FALLBACK_FILE)
    }

    companion object {
        const val KEY_PARENT_PIN = "parent_pin_hash"

        private const val FILE = "osra_secure_store"
        private const val FALLBACK_FILE = "osra_secure_store_fallback"
        private const val TAG = "SecureStore"
    }
}

/** osra-security#8 F2: which store [SecureStore] uses, as a pure rule. */
object SecureStoreOpening {
    enum class Outcome { ENCRYPTED, RESET_ENCRYPTED, PLAINTEXT_DEGRADED }

    fun decide(firstOpened: Boolean, retryOpened: Boolean): Outcome = when {
        firstOpened -> Outcome.ENCRYPTED
        retryOpened -> Outcome.RESET_ENCRYPTED
        else -> Outcome.PLAINTEXT_DEGRADED
    }
}
