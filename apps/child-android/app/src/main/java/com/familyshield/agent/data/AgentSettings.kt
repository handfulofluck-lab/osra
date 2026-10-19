package com.familyshield.agent.data

import android.content.Context
import androidx.datastore.core.DataStore
import androidx.datastore.preferences.core.Preferences
import androidx.datastore.preferences.core.edit
import androidx.datastore.preferences.core.stringPreferencesKey
import androidx.datastore.preferences.preferencesDataStore
import com.familyshield.agent.receivers.AlertThrottlePolicy
import com.familyshield.agent.receivers.InstallAlertPolicy
import dagger.hilt.android.qualifiers.ApplicationContext
import javax.inject.Inject
import javax.inject.Singleton
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.runBlocking

private val Context.familyShieldDataStore: DataStore<Preferences> by preferencesDataStore(
    name = "familyshield_settings",
)

/**
 * Typed access to the agent's DataStore-backed identity/settings. OkHttp interceptors read the
 * synchronous cached snapshots ([deviceTokenSync], [hmacSecretSync]) because they cannot suspend.
 */
@Singleton
class AgentSettings @Inject constructor(
    @ApplicationContext context: Context,
    private val secure: com.familyshield.agent.security.SecureStore,
) {
    private val store = context.familyShieldDataStore

    @Volatile private var deviceIdCache: String? = null
    @Volatile private var childIdCache: String? = null
    @Volatile private var tokenCache: String? = null
    @Volatile private var hmacCache: String? = null
    @Volatile private var hmacLoaded: Boolean = false
    @Volatile private var baseUrlCache: String? = null
    @Volatile private var baseUrlLoaded: Boolean = false
    @Volatile private var tokenLoaded: Boolean = false

    /** Returns the enrolled device id, or null when not yet provisioned. */
    suspend fun deviceId(): String? = read(KEY_DEVICE_ID).also { deviceIdCache = it }

    /** Returns the enrolled child id, or null when not yet provisioned. */
    suspend fun childId(): String? = read(KEY_CHILD_ID).also { childIdCache = it }

    /** Returns the device JWT used for device-authenticated calls, or null. */
    suspend fun deviceToken(): String? = readSecret(KEY_DEVICE_TOKEN, SECURE_DEVICE_TOKEN).also {
        tokenCache = it
        tokenLoaded = true
    }

    /** Returns the HMAC secret for internal calls, or null when not provisioned (fail-closed). */
    suspend fun hmacSecret(): String? = readSecret(KEY_HMAC_SECRET, SECURE_HMAC_SECRET).also {
        hmacCache = it
        hmacLoaded = true
    }

    /**
     * Plan 1.8: the device JWT and the per-device HMAC secret live in the keystore-backed
     * [com.familyshield.agent.security.SecureStore]. A value still in plaintext DataStore from an
     * older build is migrated on first read (copied into the encrypted store, then removed).
     */
    private suspend fun readSecret(plainKey: Preferences.Key<String>, secureKey: String): String? {
        secure.getString(secureKey)?.let { return it }
        val legacy = read(plainKey) ?: return null
        secure.putString(secureKey, legacy)
        store.edit { it.remove(plainKey) }
        return legacy
    }

    /** Persists the latest rule set JSON. */
    suspend fun saveRulesJson(json: String) {
        store.edit { it[KEY_RULES_JSON] = json }
    }

    /** Returns the persisted rule set JSON, or null. */
    suspend fun rulesJson(): String? = read(KEY_RULES_JSON)

    /** Persists the merged default-category blocklist (packageId -> category JSON). */
    suspend fun saveBlocklistJson(json: String) {
        store.edit { it[KEY_BLOCKLIST_JSON] = json }
    }

    /** Returns the persisted merged blocklist JSON, or null. */
    suspend fun blocklistJson(): String? = read(KEY_BLOCKLIST_JSON)

    suspend fun saveBlocklistDomainsJson(json: String) {
        store.edit { it[KEY_BLOCKLIST_DOMAINS_JSON] = json }
    }

    suspend fun blocklistDomainsJson(): String? = read(KEY_BLOCKLIST_DOMAINS_JSON)

    /**
     * Synchronous snapshot of the device JWT for interceptors.
     * // NOTE: blocking read once per process — interceptors cannot suspend. Without this, a cold
     * process (e.g. after reboot, before any suspend read) would send requests unsigned.
     */
    fun deviceTokenSync(): String? {
        if (!tokenLoaded) {
            synchronized(this) {
                if (!tokenLoaded) {
                    tokenCache = runBlocking { readSecret(KEY_DEVICE_TOKEN, SECURE_DEVICE_TOKEN) }
                    tokenLoaded = true
                }
            }
        }
        return tokenCache
    }

    /**
     * Synchronous cached snapshot of the HMAC secret for interceptors.
     * // NOTE: blocking read once per process — same cold-start guard as [deviceTokenSync];
     * without it, a fresh process would send internal requests unsigned (secret null until
     * the first suspend read loads it), and the server rejects them with 401 (fail-closed).
     */
    fun hmacSecretSync(): String? {
        if (!hmacLoaded) {
            synchronized(this) {
                if (!hmacLoaded) {
                    hmacCache = runBlocking { readSecret(KEY_HMAC_SECRET, SECURE_HMAC_SECRET) }
                    hmacLoaded = true
                }
            }
        }
        return hmacCache
    }

    /** Returns the paired server base URL, or null when not yet provisioned. */
    suspend fun baseUrl(): String? = read(KEY_BASE_URL).also {
        baseUrlCache = it
        baseUrlLoaded = true
    }

    /** True when a device JWT is stored (paired). */
    suspend fun isPaired(): Boolean = deviceToken() != null

    /** Persists the pairing result (§14.2) and refreshes the interceptor caches. */
    suspend fun savePairing(baseUrl: String, deviceJwt: String, deviceId: String, childId: String, hmacSecret: String? = null) {
        secure.putString(SECURE_DEVICE_TOKEN, deviceJwt)
        if (hmacSecret != null) secure.putString(SECURE_HMAC_SECRET, hmacSecret)
        store.edit {
            it[KEY_BASE_URL] = baseUrl
            it.remove(KEY_DEVICE_TOKEN)
            it[KEY_DEVICE_ID] = deviceId
            it[KEY_CHILD_ID] = childId
            if (hmacSecret != null) it.remove(KEY_HMAC_SECRET)
        }
        baseUrlCache = baseUrl
        tokenCache = deviceJwt
        deviceIdCache = deviceId
        childIdCache = childId
        if (hmacSecret != null) hmacCache = hmacSecret
        baseUrlLoaded = true
        tokenLoaded = true
    }

    /** Clears pairing state (re-pair); rules/HMAC stay. */
    suspend fun clearPairing() {
        secure.putString(SECURE_DEVICE_TOKEN, null)
        store.edit {
            it.remove(KEY_BASE_URL)
            it.remove(KEY_DEVICE_TOKEN)
            it.remove(KEY_DEVICE_ID)
            it.remove(KEY_CHILD_ID)
        }
        baseUrlCache = null
        tokenCache = null
        deviceIdCache = null
        childIdCache = null
        tokenLoaded = true // loaded, and known to be null
    }

    /**
     * Synchronous snapshot of the stored base URL for interceptors.
     * // NOTE: blocking read once per process — interceptors cannot suspend.
     */
    fun baseUrlSync(): String? {
        if (!baseUrlLoaded) {
            synchronized(this) {
                if (!baseUrlLoaded) {
                    baseUrlCache = runBlocking { read(KEY_BASE_URL) }
                    baseUrlLoaded = true
                }
            }
        }
        return baseUrlCache
    }

    /** Returns the epoch-ms of the last install_request alert for [packageId], or null (Feature #8). */
    suspend fun installAlertTimestamp(packageId: String): Long? =
        read(stringPreferencesKey(InstallAlertPolicy.throttleKey(packageId)))?.toLongOrNull()

    /** Records that an install_request alert was raised for [packageId] at [nowMs] (Feature #8). */
    suspend fun recordInstallAlert(packageId: String, nowMs: Long) {
        store.edit { it[stringPreferencesKey(InstallAlertPolicy.throttleKey(packageId))] = nowMs.toString() }
    }

    /** Returns the epoch-ms of the last tamper/VPN alert of [type], or null (Features #19/#20). */
    suspend fun tamperAlertTimestamp(type: String): Long? =
        read(stringPreferencesKey(AlertThrottlePolicy.throttleKey(type)))?.toLongOrNull()

    /** Records that a tamper/VPN alert of [type] was raised at [nowMs] (Features #19/#20). */
    suspend fun recordTamperAlert(type: String, nowMs: Long) {
        store.edit { it[stringPreferencesKey(AlertThrottlePolicy.throttleKey(type))] = nowMs.toString() }
    }

    /** Persists today's usage counters snapshot for persistence across reboots (AND-02). */
    suspend fun saveTodayUsage(date: String, json: String) {
        store.edit {
            it[KEY_TODAY_USAGE_DATE] = date
            it[KEY_TODAY_USAGE_JSON] = json
        }
    }

    /** Returns the date string for the persisted today-usage snapshot, or null. */
    suspend fun todayUsageDate(): String? = read(KEY_TODAY_USAGE_DATE)

    /** Returns the persisted today-usage snapshot JSON, or null. */
    suspend fun todayUsageJson(): String? = read(KEY_TODAY_USAGE_JSON)

    /** Synchronous snapshot of pairing status (device token present). */
    fun isPairedSync(): Boolean = !deviceTokenSync().isNullOrBlank()

    /** Persists the consent-pause flag (ADR-0008 §3) so a reboot while paused stays paused. */
    suspend fun saveConsentPaused(paused: Boolean) {
        store.edit { it[KEY_CONSENT_PAUSED] = if (paused) "1" else "0" }
    }

    /** Last uploaded installed-apps fingerprint (roadmap 3.4), or null before the first report. */
    suspend fun installedAppsReportHash(): String? = read(KEY_INSTALLED_APPS_HASH)

    /** Epoch-ms of the last successful installed-apps upload, or null. */
    suspend fun installedAppsReportedAt(): Long? = read(KEY_INSTALLED_APPS_REPORTED_AT)?.toLongOrNull()

    /** Records a successful inventory upload so an unchanged list is not sent again for 24 h. */
    suspend fun saveInstalledAppsReport(hash: String, reportedAt: Long) {
        store.edit {
            it[KEY_INSTALLED_APPS_HASH] = hash
            it[KEY_INSTALLED_APPS_REPORTED_AT] = reportedAt.toString()
        }
    }

    /** Synchronous cold-start read of the consent-pause flag (once per process). */
    fun consentPausedSync(): Boolean = runBlocking { read(KEY_CONSENT_PAUSED) } == "1"

    private suspend fun read(key: Preferences.Key<String>): String? = store.data.first()[key]

    companion object {
        private val KEY_DEVICE_ID = stringPreferencesKey("device_id")
        private val KEY_CHILD_ID = stringPreferencesKey("child_id")
        private val KEY_DEVICE_TOKEN = stringPreferencesKey("device_token")
        private val KEY_HMAC_SECRET = stringPreferencesKey("hmac_secret")
        private const val SECURE_DEVICE_TOKEN = "device_token"
        private const val SECURE_HMAC_SECRET = "hmac_secret"
        private val KEY_RULES_JSON = stringPreferencesKey("rules_json")
        private val KEY_BLOCKLIST_JSON = stringPreferencesKey("blocklist_json")
        private val KEY_BLOCKLIST_DOMAINS_JSON = stringPreferencesKey("blocklist_domains_json")
        private val KEY_BASE_URL = stringPreferencesKey("base_url")
        private val KEY_TODAY_USAGE_DATE = stringPreferencesKey("today_usage_date")
        private val KEY_TODAY_USAGE_JSON = stringPreferencesKey("today_usage_json")
        private val KEY_CONSENT_PAUSED = stringPreferencesKey("consent_paused")
        // Roadmap 3.4: change detection for the installed-app inventory upload.
        private val KEY_INSTALLED_APPS_HASH = stringPreferencesKey("installed_apps_hash")
        private val KEY_INSTALLED_APPS_REPORTED_AT = stringPreferencesKey("installed_apps_reported_at")
    }
}
