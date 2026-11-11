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
 * wrote new ones in plaintext. Now ([SecureStoreOpener]):
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
        val opener = SecureStoreOpener(
            openEncrypted = ::encrypted,
            openPlain = { context.getSharedPreferences(FALLBACK_FILE, Context.MODE_PRIVATE) },
            deleteFile = { context.deleteSharedPreferences(it) },
            entries = { prefs -> prefs.all.filterValues { it is String }.mapValues { it.value as String } },
            contains = { prefs, key -> prefs.contains(key) },
            putAll = { prefs, values -> prefs.edit().apply { values.forEach { (k, v) -> putString(k, v) } }.commit() },
            log = { message, error -> Log.e(TAG, message, error) },
        )
        return opener.open(FILE, FALLBACK_FILE).also { degraded = opener.degraded }
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

    companion object {
        const val KEY_PARENT_PIN = "parent_pin_hash"

        private const val FILE = "osra_secure_store"
        private const val FALLBACK_FILE = "osra_secure_store_fallback"
        private const val TAG = "SecureStore"
    }
}

/**
 * osra-security#8 F2: the opening sequence, with its effects passed in so the tests drive it with fakes ([SecureStore]
 * passes the real ones). `S` is the store type: `SharedPreferences` in the app, a map in the tests.
 */
class SecureStoreOpener<S>(
    private val openEncrypted: () -> S,
    private val openPlain: () -> S,
    private val deleteFile: (String) -> Unit,
    private val entries: (S) -> Map<String, String>,
    private val contains: (S, String) -> Boolean,
    private val putAll: (S, Map<String, String>) -> Unit,
    private val log: (String, Throwable?) -> Unit = { _, _ -> },
) {
    /** True once [open] had to use the plaintext store because no encrypted store would open. */
    var degraded: Boolean = false
        private set

    fun open(file: String, fallbackFile: String): S {
        // Twice on the same file first: one passing Keystore failure must not cost the pairing.
        val first = runCatching(openEncrypted).let { if (it.isSuccess) it else runCatching(openEncrypted) }
        if (first.isSuccess) {
            val store = first.getOrThrow()
            // Secrets an older build left in plaintext move in (never over a value already there), then that file goes.
            val plain = openPlain()
            val leftovers = entries(plain).filterKeys { !contains(store, it) }
            if (leftovers.isNotEmpty()) putAll(store, leftovers)
            deleteFile(fallbackFile)
            return store
        }
        log("encrypted store unreadable; deleting it and opening it fresh", first.exceptionOrNull())
        deleteFile(file)
        val retry = runCatching(openEncrypted)
        if (retry.isSuccess) {
            deleteFile(fallbackFile)
            return retry.getOrThrow()
        }
        log("Keystore cannot open an encrypted store on this phone; using the plaintext fallback", retry.exceptionOrNull())
        degraded = true
        return openPlain()
    }
}
