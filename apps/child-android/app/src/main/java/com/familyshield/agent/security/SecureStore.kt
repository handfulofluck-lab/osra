package com.familyshield.agent.security

import android.content.Context
import android.content.SharedPreferences
import android.util.Log
import androidx.security.crypto.EncryptedSharedPreferences
import androidx.security.crypto.MasterKey
import dagger.hilt.android.qualifiers.ApplicationContext
import javax.inject.Inject
import javax.inject.Singleton

private const val FILE = "osra_secure_store"
private const val FALLBACK_FILE = "osra_secure_store_fallback"
private const val TAG = "SecureStore"

/**
 * AES-256-GCM EncryptedSharedPreferences (ADR-0010) for the values that are genuinely sensitive on the device: the
 * parent-PIN hash, the device JWT and the per-device HMAC secret.
 *
 * osra-security#8 F2 (hardened after Ahmed's review, which supersedes the #563 plaintext fallback): opening used to
 * fall back to plain prefs on **any** failure, silently. A restored backup is one such failure (the file comes back,
 * its Keystore key does not), and the agent then read every secret as missing and wrote new ones in plaintext.
 * Now ([SecureStoreOpener]):
 * 1. the encrypted store opens: use it, and move anything an older build left in the plaintext fallback into it, then
 *    delete that file;
 * 2. it fails twice in a row (once could be a passing Keystore hiccup, which must not cost the pairing): the encrypted
 *    file is unreadable, so it is deleted and opened fresh. The phone reads as unpaired and re-pairs; nothing is
 *    written in plaintext;
 * 3. it still does not (the Keystore itself is broken on this phone): fail closed. The legacy plaintext fallback is
 *    deleted, nothing is ever opened or written in plaintext, and [unreadable] records the state. The store reads as
 *    empty, so the phone is not paired, shows the re-pair message, and its next pairing claim flags `dataCleared`
 *    (the server then records the tamper alert on the parent's Allow). A salted PBKDF2 hash is not the PIN.
 *
 * The fail-closed flag lives in memory, never on disk: it is re-evaluated on every open, and [reopenIfUnreadable]
 * retries the encrypted store when the Keystore recovers, so a later successful pairing works again without a restart.
 */
@Singleton
class SecureStore internal constructor(
    private val openerFactory: () -> SecureStoreOpener<SharedPreferences>,
) {
    @Inject constructor(@ApplicationContext context: Context) : this({
        SecureStoreOpener<SharedPreferences>(
            openEncrypted = { encrypted(context) },
            openPlain = { context.getSharedPreferences(FALLBACK_FILE, Context.MODE_PRIVATE) },
            empty = { NoopSharedPreferences() },
            deleteFile = { context.deleteSharedPreferences(it) },
            entries = { store -> store.all.filterValues { it is String }.mapValues { it.value as String } },
            contains = { store, key -> store.contains(key) },
            putAll = { store, values -> store.edit().apply { values.forEach { (k, v) -> putString(k, v) } }.commit() },
            log = { message, error -> Log.e(TAG, message, error) },
        )
    })

    @Volatile private var prefs: SharedPreferences? = null

    /** True when the encrypted store could not be opened at all (fail-closed, step 3). */
    @Volatile private var unreadableFlag: Boolean = false

    /** True when the encrypted store could not be opened at all (fail-closed); forces the store open once. */
    val unreadable: Boolean
        get() {
            ensureOpen()
            return unreadableFlag
        }

    fun putString(key: String, value: String?) {
        ensureOpen().edit().apply { if (value == null) remove(key) else putString(key, value) }.apply()
    }

    fun getString(key: String): String? = ensureOpen().getString(key, null)

    /**
     * Retries the encrypted store when it was fail-closed (the Keystore may have recovered), clearing [unreadable] on
     * success. @return true when the store is now writable; false when it is still unreadable.
     */
    fun reopenIfUnreadable(): Boolean {
        ensureOpen()
        if (!unreadableFlag) return true
        synchronized(this) {
            if (!unreadableFlag) return true
            prefs = null
            unreadableFlag = false
            ensureOpen()
            return !unreadableFlag
        }
    }

    private fun ensureOpen(): SharedPreferences {
        prefs?.let { return it }
        synchronized(this) {
            prefs?.let { return it }
            val opener = openerFactory()
            val opened = opener.open(FILE, FALLBACK_FILE)
            prefs = opened
            unreadableFlag = opener.unreadable
            return opened
        }
    }

    companion object {
        const val KEY_PARENT_PIN = "parent_pin_hash"
    }
}

private fun encrypted(context: Context): SharedPreferences {
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

/**
 * osra-security#8 F2: the opening sequence, with its effects passed in so the tests drive it with fakes ([SecureStore]
 * passes the real ones). `S` is the store type: `SharedPreferences` in the app, a map in the tests.
 *
 * [empty] is what fail-closed returns: an in-memory store that holds nothing and discards every write, so a secret is
 * never persisted in plaintext. It is the only store returned when no encrypted store will open.
 */
class SecureStoreOpener<S>(
    private val openEncrypted: () -> S,
    private val openPlain: () -> S,
    private val empty: () -> S,
    private val deleteFile: (String) -> Unit,
    private val entries: (S) -> Map<String, String>,
    private val contains: (S, String) -> Boolean,
    private val putAll: (S, Map<String, String>) -> Unit,
    private val log: (String, Throwable?) -> Unit = { _, _ -> },
) {
    /** True once [open] failed closed because no encrypted store would open. */
    var unreadable: Boolean = false
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
        log("Keystore cannot open an encrypted store on this phone; failing closed, not writing plaintext", retry.exceptionOrNull())
        unreadable = true
        // The legacy plaintext fallback is deleted, never read into the fail-closed store: nothing is written in plaintext.
        deleteFile(fallbackFile)
        return empty()
    }
}

/**
 * Fail-closed store (step 3): holds nothing and discards every write, so [SecureStore] reads every key as absent and
 * never persists a secret in plaintext. `commit()` reports success so a caller that checks it does not fall back to
 * another file. In-memory only — nothing touches disk.
 */
internal class NoopSharedPreferences : SharedPreferences, SharedPreferences.Editor {
    override fun getAll(): MutableMap<String, *> = mutableMapOf<String, Any>()
    override fun getString(key: String?, defValue: String?): String? = defValue
    override fun getStringSet(key: String?, defValues: MutableSet<String>?): MutableSet<String>? = defValues
    override fun getInt(key: String?, defValue: Int): Int = defValue
    override fun getLong(key: String?, defValue: Long): Long = defValue
    override fun getFloat(key: String?, defValue: Float): Float = defValue
    override fun getBoolean(key: String?, defValue: Boolean): Boolean = defValue
    override fun contains(key: String?): Boolean = false
    override fun edit(): SharedPreferences.Editor = this
    override fun registerOnSharedPreferenceChangeListener(listener: SharedPreferences.OnSharedPreferenceChangeListener?) = Unit
    override fun unregisterOnSharedPreferenceChangeListener(listener: SharedPreferences.OnSharedPreferenceChangeListener?) = Unit

    override fun putString(key: String?, value: String?): SharedPreferences.Editor = this
    override fun putStringSet(key: String?, values: MutableSet<String>?): SharedPreferences.Editor = this
    override fun putInt(key: String?, value: Int): SharedPreferences.Editor = this
    override fun putLong(key: String?, value: Long): SharedPreferences.Editor = this
    override fun putFloat(key: String?, value: Float): SharedPreferences.Editor = this
    override fun putBoolean(key: String?, value: Boolean): SharedPreferences.Editor = this
    override fun remove(key: String?): SharedPreferences.Editor = this
    override fun clear(): SharedPreferences.Editor = this
    override fun commit(): Boolean = true
    override fun apply() = Unit
}
