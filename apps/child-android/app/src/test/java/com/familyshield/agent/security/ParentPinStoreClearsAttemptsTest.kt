package com.familyshield.agent.security

import android.content.SharedPreferences
import org.junit.Assert.assertEquals
import org.junit.Test

/**
 * #792 (Antigravity B2), the row Antigravity's mutation pass found missing (`S2` survived): deleting the
 * `clearAttempts(...)` call in [ParentPinStore.set] and [ParentPinStore.clear] passed every suite.
 *
 * The defect it protects is concrete: a parent who mistyped the old PIN eight times, then set a new one, would find
 * the **new** PIN locked for an hour on the first typo, because the debt belonged to a PIN that no longer exists.
 *
 * Pure JUnit — no Robolectric, no Android runtime. [SecureStore] takes an opener, so the store here is a
 * [SharedPreferences] fake over a map (the same shape as `SecureStoreReopenTest`), and [PinAttemptStore] is pointed at
 * the **same** store the way `StorageModule` points it in production.
 *
 * Mutant: delete `clearAttempts(secureStore)` from `set()` (or `clear()`) → this row goes red.
 */
class ParentPinStoreClearsAttemptsTest {

    @Test
    fun `setting a new PIN wipes the wrong-try debt that belonged to the old one`() {
        val store = secureStore()
        val attempts = attemptStore(store)

        // Eight wrong tries on the old PIN: past the lockout threshold, with every field populated.
        attempts.write(
            PinLockout.State(
                failures = 8,
                lastFailureMs = 1_700_000_000_000L,
                lastFailureElapsedMs = 42_000L,
                lastFailureBootCount = 3,
                alertedAt = 4,
            ),
        )
        assertEquals("the debt is there before the PIN changes", 8, attempts.read().failures)

        ParentPinStore(store).set("123456")

        assertEquals(
            "a new PIN starts with no debt, so the first typo is not an hour-long lock",
            PinLockout.CLEARED,
            attempts.read(),
        )
    }

    @Test
    fun `clearing the PIN takes its debt with it`() {
        val store = secureStore()
        val attempts = attemptStore(store)
        ParentPinStore(store).set("123456")
        attempts.write(PinLockout.State(failures = 5, lastFailureMs = 1_000L, lastFailureElapsedMs = 2_000L))

        ParentPinStore(store).clear()

        assertEquals(
            "an unpair leaves no count behind for the next PIN to inherit",
            PinLockout.CLEARED,
            attempts.read(),
        )
    }

    /** [PinAttemptStore] over the same store, exactly as `StorageModule.providePinAttemptStorage` wires it. */
    private fun attemptStore(store: SecureStore) = PinAttemptStore(
        object : PinAttemptStorage {
            override fun get(key: String): String? = store.getString(key)
            override fun put(key: String, value: String?) = store.putString(key, value)
        },
    )

    private fun secureStore(): SecureStore = SecureStore(
        openerFactory = {
            SecureStoreOpener<SharedPreferences>(
                openEncrypted = { MapPrefs() },
                openPlain = { MapPrefs() },
                empty = { NoopPrefs() },
                deleteFile = { },
                entries = { prefs -> prefs.all.filterValues { it is String }.mapValues { it.value as String } },
                contains = { prefs, key -> prefs.contains(key) },
                putAll = { prefs, values ->
                    prefs.edit().apply { values.forEach { (k, v) -> putString(k, v) } }.commit()
                },
                log = { _, _ -> },
            )
        },
    )

    private class MapPrefs : SharedPreferences {
        private val values = HashMap<String, Any?>()

        override fun getAll(): MutableMap<String, *> = HashMap(values)
        override fun getString(key: String?, defValue: String?): String? = values[key] as? String ?: defValue
        @Suppress("UNCHECKED_CAST")
        override fun getStringSet(key: String?, defValues: MutableSet<String>?): MutableSet<String>? =
            values[key] as? MutableSet<String> ?: defValues
        override fun getInt(key: String?, defValue: Int): Int = values[key] as? Int ?: defValue
        override fun getLong(key: String?, defValue: Long): Long = values[key] as? Long ?: defValue
        override fun getFloat(key: String?, defValue: Float): Float = values[key] as? Float ?: defValue
        override fun getBoolean(key: String?, defValue: Boolean): Boolean = values[key] as? Boolean ?: defValue
        override fun contains(key: String?): Boolean = values.containsKey(key)
        override fun edit(): SharedPreferences.Editor = Editor()
        override fun registerOnSharedPreferenceChangeListener(l: SharedPreferences.OnSharedPreferenceChangeListener?) = Unit
        override fun unregisterOnSharedPreferenceChangeListener(l: SharedPreferences.OnSharedPreferenceChangeListener?) = Unit

        private inner class Editor : SharedPreferences.Editor {
            private val pending = HashMap<String, Any?>()
            private val removals = HashSet<String>()

            override fun putString(key: String?, value: String?) = apply { if (key != null && value != null) pending[key] = value }
            override fun putStringSet(key: String?, values: MutableSet<String>?) = apply { if (key != null && values != null) pending[key] = values }
            override fun putInt(key: String?, value: Int) = apply { if (key != null) pending[key] = value }
            override fun putLong(key: String?, value: Long) = apply { if (key != null) pending[key] = value }
            override fun putFloat(key: String?, value: Float) = apply { if (key != null) pending[key] = value }
            override fun putBoolean(key: String?, value: Boolean) = apply { if (key != null) pending[key] = value }
            override fun remove(key: String?) = apply { if (key != null) removals.add(key) }

            override fun clear() = apply {
                values.keys.toList().forEach { removals.add(it) }
                pending.clear()
            }

            override fun commit(): Boolean {
                removals.forEach { values.remove(it) }
                values.putAll(pending)
                return true
            }

            override fun apply() {
                commit()
            }
        }
    }

    /** The store `SecureStore` uses when the encrypted one cannot be opened; unused here but required by the opener. */
    private class NoopPrefs : SharedPreferences {
        override fun getAll(): MutableMap<String, *> = HashMap<String, Any?>()
        override fun getString(key: String?, defValue: String?): String? = defValue
        override fun getStringSet(key: String?, defValues: MutableSet<String>?): MutableSet<String>? = defValues
        override fun getInt(key: String?, defValue: Int): Int = defValue
        override fun getLong(key: String?, defValue: Long): Long = defValue
        override fun getFloat(key: String?, defValue: Float): Float = defValue
        override fun getBoolean(key: String?, defValue: Boolean): Boolean = defValue
        override fun contains(key: String?): Boolean = false
        override fun edit(): SharedPreferences.Editor = object : SharedPreferences.Editor {
            override fun putString(key: String?, value: String?) = this
            override fun putStringSet(key: String?, values: MutableSet<String>?) = this
            override fun putInt(key: String?, value: Int) = this
            override fun putLong(key: String?, value: Long) = this
            override fun putFloat(key: String?, value: Float) = this
            override fun putBoolean(key: String?, value: Boolean) = this
            override fun remove(key: String?) = this
            override fun clear() = this
            override fun commit(): Boolean = true
            override fun apply() = Unit
        }
        override fun registerOnSharedPreferenceChangeListener(l: SharedPreferences.OnSharedPreferenceChangeListener?) = Unit
        override fun unregisterOnSharedPreferenceChangeListener(l: SharedPreferences.OnSharedPreferenceChangeListener?) = Unit
    }
}
