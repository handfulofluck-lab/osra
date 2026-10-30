package com.familyshield.agent.data

import android.content.Context
import androidx.datastore.core.DataStore
import androidx.datastore.preferences.core.Preferences
import androidx.datastore.preferences.core.edit
import androidx.datastore.preferences.core.stringPreferencesKey
import androidx.datastore.preferences.preferencesDataStore
import com.familyshield.agent.receivers.AlertThrottlePolicy
import com.familyshield.agent.receivers.InstallAlertPolicy
import com.familyshield.agent.security.TamperState
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
    @ApplicationContext private val context: Context,
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

    /**
     * Issue #465: drop the cached rule set when this phone is no longer linked to a family. The last
     * rules the server sent are the ones a deleted family's phone would otherwise keep enforcing.
     */
    suspend fun forgetRules() {
        store.edit { it.remove(KEY_RULES_JSON) }
    }

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
            // Issue #221: a re-pair is a new device identity, so the next grant report is a first
            // report rather than a change the expedited upload should skip.
            it.remove(KEY_REPORTED_LOCATION_GRANT)
            // Issue #225: after a re-pair the next accessibility/overlay check is a first observation again.
            it.remove(KEY_ACCESSIBILITY_WAS_ENABLED)
            it.remove(KEY_OVERLAY_WAS_GRANTED)
            // Issue #319: the enrolment is new, so the token has to be published to it again. The token
            // itself is kept — an FCM registration token belongs to the install, not to the pairing.
            it.remove(KEY_PUSH_TOKEN_UPLOADED)
        }
        // Issue #227: a re-pair is a new device enrolment; its first guard attempt opens a new window.
        TamperState.clearGuardAttemptWindow(context)
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

    /** Persists today's usage counters snapshot, in milliseconds, across reboots (AND-02, #276). */
    suspend fun saveTodayUsage(date: String, json: String) {
        store.edit {
            it[KEY_TODAY_USAGE_DATE] = date
            it[KEY_TODAY_USAGE_JSON] = json
            it[KEY_TODAY_USAGE_UNIT] = USAGE_UNIT_MS
        }
    }

    /** Returns the date string for the persisted today-usage snapshot, or null. */
    suspend fun todayUsageDate(): String? = read(KEY_TODAY_USAGE_DATE)

    /** Returns the persisted today-usage snapshot JSON, or null. */
    suspend fun todayUsageJson(): String? = read(KEY_TODAY_USAGE_JSON)

    /**
     * Unit of the persisted today-usage snapshot, or null for one written before #276 (whole
     * minutes). Reading absent as ms would shrink a mid-day upgrade's count by 60×.
     */
    suspend fun todayUsageUnit(): String? = read(KEY_TODAY_USAGE_UNIT)

    /**
     * Per-package sub-minute remainder from the last telemetry window (#276), encoded
     * `pkg=ms;pkg=ms` like [usageStatsSnapshot]; empty before the first upload.
     */
    suspend fun usageRemainderMs(): Map<String, Long> {
        val raw = read(KEY_USAGE_REMAINDER_MS) ?: return emptyMap()
        return raw.split(';')
            .mapNotNull { entry ->
                val name = entry.substringBefore('=', "")
                val ms = entry.substringAfter('=', "").toLongOrNull()
                if (name.isEmpty() || ms == null) null else name to ms
            }
            .toMap()
    }

    /** Replaces the #276 remainder, written with the upload's watermark so a failed POST keeps it. */
    suspend fun setUsageRemainderMs(remainders: Map<String, Long>) {
        store.edit {
            it[KEY_USAGE_REMAINDER_MS] = remainders.entries.joinToString(";") { (pkg, ms) -> "$pkg=$ms" }
        }
    }

    /** Synchronous snapshot of pairing status (device token present). */
    fun isPairedSync(): Boolean = !deviceTokenSync().isNullOrBlank()

    /**
     * Persists the pause flag with the withdrawal counter and the re-grant time (issue #257 review), so
     * a restart keeps the same epoch and the comms restart point survives a reboot.
     */
    suspend fun saveConsentState(paused: Boolean, pauseEpoch: Long, resumedAtMs: Long) {
        store.edit {
            it[KEY_CONSENT_PAUSED] = if (paused) "1" else "0"
            it[KEY_CONSENT_PAUSE_EPOCH] = pauseEpoch.toString()
            it[KEY_CONSENT_RESUMED_AT] = resumedAtMs.toString()
        }
    }

    /** Epoch of observed withdrawals, for [ConsentState]'s in-memory copy. */
    fun consentPauseEpochSync(): Long = runBlocking { read(KEY_CONSENT_PAUSE_EPOCH) }?.toLongOrNull() ?: 0L

    /** When consent was last re-granted, for [ConsentState]'s in-memory copy. */
    fun consentResumedAtSync(): Long = runBlocking { read(KEY_CONSENT_RESUMED_AT) }?.toLongOrNull() ?: 0L

    /**
     * Issue #221 (D1 follow-up): the location grant the server was last told about. The expedited
     * upload sends a report only when this differs from the grant read now, so a resume or a
     * permission callback that changes nothing costs no request.
     */
    suspend fun reportedLocationGrant(): String? = read(KEY_REPORTED_LOCATION_GRANT)

    /** Records the grant a successful upload covered, so the same value is not re-sent. */
    suspend fun recordReportedLocationGrant(grant: String) {
        store.edit { it[KEY_REPORTED_LOCATION_GRANT] = grant }
    }

    /**
     * Issue #267 review: the **bucket** and the per-package UsageStats totals at the last backfill.
     *
     * Android rolls its `INTERVAL_DAILY` bucket at a time the device picks — measured at 20:07 on the
     * Flip4 — so a snapshot keyed by the calendar date re-sent up to four hours every morning. The key
     * is the bucket's own begin time, which is what makes "same bucket" mean the same thing Android does.
     *
     * Encoded as `bucketBegin|pkg=minutes;pkg=minutes` — package names contain no `|`, `;` or `=`, so no
     * escaping is needed and the whole thing stays one preference rather than a table for two numbers per
     * app. Returns `(null, empty)` on a device that has never backfilled.
     */
    suspend fun usageStatsSnapshot(): Pair<Long?, Map<String, Int>> {
        val raw = read(KEY_USAGE_STATS_SNAPSHOT) ?: return null to emptyMap()
        val bucket = raw.substringBefore('|').toLongOrNull()
        val totals = raw.substringAfter('|', "")
            .split(';')
            .mapNotNull { entry ->
                val name = entry.substringBefore('=', "")
                val minutes = entry.substringAfter('=', "").toIntOrNull()
                if (name.isEmpty() || minutes == null) null else name to minutes
            }
            .toMap()
        return bucket to totals
    }

    /** Records the snapshot a backfill covered, so the next upload sends only the increase. */
    suspend fun setUsageStatsSnapshot(bucketBegin: Long, totals: Map<String, Int>) {
        val encoded = totals.entries.joinToString(";") { "${it.key}=${it.value}" }
        store.edit { it[KEY_USAGE_STATS_SNAPSHOT] = "$bucketBegin|$encoded" }
    }

    /**
     * Issue #264 (F1): the future-dated texts already imported, so a row the clock ran ahead on is
     * uploaded once instead of on every harvest until its date arrives.
     *
     * Stored as separate preferences values separated by `\u0000` rather than a Room table: the set is
     * small (bounded by [CommsFutureSmsPolicy.MAX_TRACKED]), it is only read and written inside the
     * comms mutex, and a schema change for it would migrate a table that carries nothing else. The
     * entries are `date|id|addressDigest` — never the number itself.
     */
    suspend fun futureSmsSeen(): Set<String> =
        read(KEY_FUTURE_SMS_SEEN)
            ?.split('\u0000')
            ?.filter { it.isNotBlank() }
            ?.toSet()
            ?: emptySet()

    /** Replaces the future-dated-text set; [CommsFutureSmsPolicy] decides what it may contain. */
    suspend fun setFutureSmsSeen(entries: Set<String>) {
        store.edit { it[KEY_FUTURE_SMS_SEEN] = entries.joinToString("\u0000") }
    }

    /**
     * Issue #225: the last observation of whether the OSRA accessibility service was effectively
     * enabled, or null when it has never been observed. The tamper alert is raised only on a
     * recorded true -> false edge, so a fresh install that has not granted accessibility yet stays
     * silent.
     */
    suspend fun accessibilityWasEnabled(): Boolean? =
        read(KEY_ACCESSIBILITY_WAS_ENABLED)?.let { it == "1" }

    /** Records an accessibility observation (on or off) for the #225 transition rule. */
    suspend fun recordAccessibilityEnabled(enabled: Boolean) {
        store.edit { it[KEY_ACCESSIBILITY_WAS_ENABLED] = if (enabled) "1" else "0" }
    }

    /**
     * Issue #225: the last observation of whether the overlay permission was granted, or null when
     * it has never been observed. Same tri-state encoding as [accessibilityWasEnabled], and the
     * overlay alert is likewise raised only on a recorded true -> false edge.
     */
    suspend fun overlayWasGranted(): Boolean? =
        read(KEY_OVERLAY_WAS_GRANTED)?.let { it == "1" }

    /** Records an overlay-permission observation (granted or not) for the #225 transition rule. */
    suspend fun recordOverlayGranted(granted: Boolean) {
        store.edit { it[KEY_OVERLAY_WAS_GRANTED] = if (granted) "1" else "0" }
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

    /**
     * Issue #319: the latest FCM registration token this install received, or null before Firebase
     * mints one. Persisted because `onNewToken` also fires before pairing — a token that arrived
     * then used to be dropped (the old code uploaded only when a device id already existed), and the
     * child never got a second chance at it until FCM rotated the token.
     *
     * Plain DataStore, not [com.familyshield.agent.security.SecureStore]: a registration token
     * identifies a device to Firebase, it is not a credential this agent presents to our server, and
     * the server stores it in a plain column.
     */
    suspend fun pushToken(): String? = read(KEY_PUSH_TOKEN)

    /** Persists a token from `FirebaseMessagingService.onNewToken` (§1.5). */
    suspend fun savePushToken(token: String) {
        store.edit { it[KEY_PUSH_TOKEN] = token }
    }

    /**
     * The token the server last accepted, or null when none has been uploaded to this enrolment.
     * [com.familyshield.agent.push.PushTokenUploadPolicy] compares it with [pushToken] so the
     * 15-minute poll re-sends a token only when the two differ.
     */
    suspend fun uploadedPushToken(): String? = read(KEY_PUSH_TOKEN_UPLOADED)

    /** Records a token the server accepted, so the same one is not re-sent on every poll. */
    suspend fun recordUploadedPushToken(token: String) {
        store.edit { it[KEY_PUSH_TOKEN_UPLOADED] = token }
    }

    /** Synchronous cold-start read of the consent-pause flag (once per process). */
    fun consentPausedSync(): Boolean = runBlocking { read(KEY_CONSENT_PAUSED) } == "1"

    private suspend fun read(key: Preferences.Key<String>): String? = store.data.first()[key]

    companion object {
        /** Unit written by `saveTodayUsage` since #276; a snapshot without it holds whole minutes. */
        const val USAGE_UNIT_MS: String = "ms"

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
        // Issue #276: the snapshot switched from whole minutes to milliseconds.
        private val KEY_TODAY_USAGE_UNIT = stringPreferencesKey("today_usage_unit")
        // Issue #276: each package's sub-minute remainder, carried into the next telemetry window.
        private val KEY_USAGE_REMAINDER_MS = stringPreferencesKey("usage_remainder_ms")
        private val KEY_CONSENT_PAUSED = stringPreferencesKey("consent_paused")
        // Issue #257 review: observed-withdrawal counter and the re-grant time, so the comms
        // watermark restart does not depend on a harvest happening to run at the right moment.
        private val KEY_CONSENT_PAUSE_EPOCH = stringPreferencesKey("consent_pause_epoch")
        private val KEY_CONSENT_RESUMED_AT = stringPreferencesKey("consent_resumed_at")
        // Issue #221: the location grant the server was last told about (change detection).
        private val KEY_REPORTED_LOCATION_GRANT = stringPreferencesKey("reported_location_grant")
        // Issue #267: the bucket and per-package UsageStats totals the last backfill covered.
        private val KEY_USAGE_STATS_SNAPSHOT = stringPreferencesKey("usage_stats_snapshot")
        // Issue #225: the recorded "was enabled" state for the accessibility-off transition rule.
        private val KEY_ACCESSIBILITY_WAS_ENABLED = stringPreferencesKey("accessibility_was_enabled")
        // Issue #225: the recorded "was granted" state for the overlay-revoked transition rule.
        private val KEY_OVERLAY_WAS_GRANTED = stringPreferencesKey("overlay_was_granted")
        // Roadmap 3.4: change detection for the installed-app inventory upload.
        private val KEY_INSTALLED_APPS_HASH = stringPreferencesKey("installed_apps_hash")
        private val KEY_INSTALLED_APPS_REPORTED_AT = stringPreferencesKey("installed_apps_reported_at")
        // Issue #264 (F1): future-dated texts already imported (`\u0000`-separated `date|id|digest`).
        private val KEY_FUTURE_SMS_SEEN = stringPreferencesKey("comms_sms_future_seen")
        // Issue #319: the FCM registration token this install received, and the one the server last took.
        private val KEY_PUSH_TOKEN = stringPreferencesKey("push_token")
        private val KEY_PUSH_TOKEN_UPLOADED = stringPreferencesKey("push_token_uploaded")
    }
}
