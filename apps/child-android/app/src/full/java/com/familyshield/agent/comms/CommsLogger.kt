package com.familyshield.agent.comms

import com.familyshield.agent.BuildConfig
import android.Manifest
import android.content.Context
import android.content.pm.PackageManager
import android.database.ContentObserver
import android.database.Cursor
import android.provider.CallLog
import android.provider.Telephony
import android.util.Log
import androidx.core.content.ContextCompat
import com.familyshield.agent.data.AgentSettings
import com.familyshield.agent.data.ConsentState
import com.familyshield.agent.data.RuleRepository
import com.familyshield.agent.data.db.AgentStateEntity
import com.familyshield.agent.data.db.CommsEventEntity
import com.familyshield.agent.data.db.FamilyShieldDatabase
import com.familyshield.agent.network.ApiService
import com.familyshield.agent.network.dto.ActivityEventBatchDto
import com.familyshield.agent.network.dto.ActivityEventDto
import com.familyshield.agent.network.dto.AlertDto
import dagger.hilt.android.qualifiers.ApplicationContext
import javax.inject.Inject
import javax.inject.Singleton
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.delay
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock

/**
 * Feature #6 call + SMS logging. ContentObservers on CallLog.Calls and Telephony.Sms buffer new
 * rows into Room `comms_events`; [flush] uploads them as POST /v1/devices/<id>/activity batches
 * (runs on an in-process 5-min loop plus the 15-min TelemetryWorker as backstop). READ_CALL_LOG /
 * READ_SMS are runtime dangerous permissions — every access is guarded: missing permission logs once
 * at INFO and skips, and [onPermissionsChanged] registers an observer that was refused at start as
 * soon as its grant arrives (issue #229). Collection starts at the grant and never reads older
 * history. NOTE: iOS has no equivalent (no call-log/SMS API); the default-dialer role is intentionally
 * NOT requested — log-only mode. Feature #27: numbers not in the rule contactAllowlist (non-empty)
 * raise a throttled (1/hour/number) unknown_contact info alert.
 */
@Singleton
class CommsLogger @Inject constructor(
    @ApplicationContext private val context: Context,
    private val db: FamilyShieldDatabase,
    private val api: ApiService,
    private val settings: AgentSettings,
    private val rules: RuleRepository,
    private val consent: ConsentState,
) : CommsCapture {
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    private val lastAlertAt = HashMap<String, Long>()

    @Volatile private var started = false

    /**
     * Issue #229: one flag per stream, not one for both. `started` used to be set before either
     * registration ran, so a provider that refuses `registerContentObserver` without the permission
     * (Samsung's call log) left the app believing it was watching, and a later grant never retried.
     */
    @Volatile private var callObserverRegistered = false
    @Volatile private var smsObserverRegistered = false

    /**
     * Serialises a harvest against another harvest and against [flush]. Without it, a flush that has
     * read the table can clear a row inserted by a concurrent harvest before that row is uploaded.
     */
    private val commsMutex = Mutex()

    /** Registers the observers that are allowed now and starts the periodic flush loop (idempotent). */
    override fun start() {
        // ADR-0021: the Play artefact declares neither READ_CALL_LOG nor READ_SMS, so it must not
        // register the observers either — nothing to read, and the registration is what a reviewer sees.
        if (!BuildConfig.CAPTURE_CALL_SMS) return
        if (started) return
        started = true
        registerObservers()
        scope.launch {
            while (isActive) {
                delay(FLUSH_PERIOD_MS)
                // Issue #229: a grant made while this process was in the background is picked up
                // here even if no activity resumed and no call arrived.
                runCatching { onPermissionsChanged() }
                runCatching { flush() }
            }
        }
    }

    /**
     * Issue #229: the retry the old `start()` lacked. Registers each observer whose permission is
     * granted now, logs once at INFO (no stack — the #91 rule) for one that is still missing, and
     * harvests each registered stream once. Called from `PairingActivity`'s permission result, from
     * `PairingActivity.onResume` (the launcher screen) and from the top of the 5-minute loop.
     */
    override fun onPermissionsChanged() {
        if (!BuildConfig.CAPTURE_CALL_SMS) return
        scope.launch {
            runCatching { registerObservers() }
            runCatching { noteConsentState(db.agentStateDao()) }
            if (consent.isPaused()) return@launch // ADR-0008 §3
            if (callObserverRegistered) runCatching { harvestCalls() }
            if (smsObserverRegistered) runCatching { harvestSms() }
        }
    }

    // Issue #229: four call sites can now reach this (boot, permission result, resume, the loop), two
    // of them on the main thread; the check-then-set on each flag must not register twice.
    @Synchronized
    private fun registerObservers() {
        val resolver = context.contentResolver
        val callGranted = granted(Manifest.permission.READ_CALL_LOG)
        if (CommsObserverPolicy.shouldRegister(callGranted, callObserverRegistered)) {
            runCatching {
                resolver.registerContentObserver(CallLog.Calls.CONTENT_URI, true, callObserver)
            }.onSuccess {
                callObserverRegistered = true
                warnedCallPermission = false
            }.onFailure {
                // The permission is present but the provider refused (an OEM policy, not a missing
                // grant). One INFO line, no stack: the boot log is read on phones without the grant.
                if (!warnedCallPermission) {
                    warnedCallPermission = true
                    Log.i(TAG, "call log observer not registered (${it.javaClass.simpleName}); will retry")
                }
            }
        } else if (!callGranted) {
            reportMissingCallPermission()
        }

        val smsGranted = granted(Manifest.permission.READ_SMS)
        if (CommsObserverPolicy.shouldRegister(smsGranted, smsObserverRegistered)) {
            runCatching {
                resolver.registerContentObserver(Telephony.Sms.CONTENT_URI, true, smsObserver)
            }.onSuccess {
                smsObserverRegistered = true
                warnedSmsPermission = false
            }.onFailure {
                if (!warnedSmsPermission) {
                    warnedSmsPermission = true
                    Log.i(TAG, "SMS observer not registered (${it.javaClass.simpleName}); will retry")
                }
            }
        } else if (!smsGranted) {
            reportMissingSmsPermission()
        }
    }

    private val callObserver = object : ContentObserver(null) {
        override fun onChange(selfChange: Boolean) {
            if (consent.isPaused()) return // ADR-0008 §3
            scope.launch { runCatching { harvestCalls() } }
        }
    }

    private val smsObserver = object : ContentObserver(null) {
        override fun onChange(selfChange: Boolean) {
            if (consent.isPaused()) return // ADR-0008 §3
            scope.launch { runCatching { harvestSms() } }
        }
    }

    /**
     * Issue #91: the permission is checked BEFORE the query, not only caught afterwards. The old code
     * relied on the SecurityException and logged a full stack trace, which produced one scare per
     * session on devices without READ_CALL_LOG and trained readers to ignore the tag.
     */
    private fun granted(permission: String): Boolean =
        ContextCompat.checkSelfPermission(context, permission) == PackageManager.PERMISSION_GRANTED

    @Volatile private var warnedCallPermission = false
    @Volatile private var warnedSmsPermission = false

    /** Issue #229: one INFO line per process, never a stack, when the permission is still missing. */
    private fun reportMissingCallPermission() {
        if (warnedCallPermission) return
        warnedCallPermission = true
        Log.i(TAG, "READ_CALL_LOG not granted; call harvesting stays off until the parent grants it")
    }

    private fun reportMissingSmsPermission() {
        if (warnedSmsPermission) return
        warnedSmsPermission = true
        Log.i(TAG, "READ_SMS not granted; SMS harvesting stays off until the parent grants it")
    }

    /**
     * Issue #229: a consent withdrawal resets the collection window. A marker is stored while consent
     * is paused; the first look after a re-grant clears both watermarks and grant times, so the next
     * harvest starts at the re-grant time and rows from the paused window are never read. The marker
     * survives a process restart, so a withdrawal observed before the process died still resets the
     * window. A withdrawal and re-grant that both happen while no process is alive cannot be seen by
     * the device; [CommsWatermarkPolicy.startFrom] then still floors the read at the stored grant time.
     */
    /**
     * Restarts the comms watermarks when a consent withdrawal has been observed (issue #257 review).
     *
     * The marker used to be written by *this* function, so a pause that began and ended between two
     * 5-minute ticks was never recorded — while paused, both observers and both harvests return before
     * reaching here — and the paused-window rows were read after the re-grant. Worse, the reset ran at
     * the first harvest after the re-grant, which then read nothing and dropped the call that triggered
     * it.
     *
     * The transition is now recorded where the flag flips (`ConsentState`), and this function only
     * compares epochs. The restart point is [ConsentState.resumedAtMs] — when the phone learned consent
     * came back — so a row created just after the re-grant is still read.
     */
    private suspend fun noteConsentState(dao: com.familyshield.agent.data.db.AgentStateDao) {
        val epoch = consent.pauseEpoch()
        val stored = CommsWatermarkPolicy.normalize(dao.get(KEY_CONSENT_EPOCH))
        if (commsConsentReset(dao, stored, epoch)) return
    }

    /**
     * Pure-in-spirit reset decision, pinned by [CommsConsentPolicy.resetTo]: null means "leave the
     * watermarks alone"; a value is the timestamp every watermark restarts from.
     */
    private suspend fun commsConsentReset(
        dao: com.familyshield.agent.data.db.AgentStateDao,
        storedEpoch: Long?,
        epoch: Long,
    ): Boolean {
        val from = CommsConsentPolicy.resetTo(
            storedEpoch = storedEpoch,
            epoch = epoch,
            paused = consent.isPaused(),
            resumedAtMs = consent.resumedAtMs(),
        ) ?: return false
        dao.set(AgentStateEntity(KEY_CONSENT_EPOCH, epoch))
        for (key in listOf(KEY_CALL_WATERMARK, KEY_SMS_WATERMARK, KEY_CALL_SINCE, KEY_SMS_SINCE)) {
            dao.set(AgentStateEntity(key, from))
        }
        return true
    }

    /**
     * Reads CallLog rows newer than the stored watermark into Room (guarded by permission checks).
     *
     * Issue #229: with no watermark yet this is the first harvest since the permission was allowed,
     * so it stores "now" as the grant time and the watermark and reads nothing — the phone's earlier
     * history is never imported. [CommsWatermarkPolicy.startFrom] also floors the read at that grant
     * time. Rows the row policy rejects (a numberless app call, a repeat inside this harvest) still
     * advance the watermark, so they are not re-read every five minutes.
     */
    private suspend fun harvestCalls() = commsMutex.withLock {
        when (CommsAccessPolicy.decide(granted(Manifest.permission.READ_CALL_LOG), warnedCallPermission)) {
            CommsAccessPolicy.Decision.HARVEST -> Unit
            CommsAccessPolicy.Decision.SKIP_QUIETLY -> return@withLock
            CommsAccessPolicy.Decision.SKIP_AND_REPORT -> {
                reportMissingCallPermission()
                return@withLock
            }
        }
        val dao = db.agentStateDao()
        noteConsentState(dao)
        if (consent.isPaused()) return@withLock // ADR-0008 §3
        val now = System.currentTimeMillis()
        val stored = CommsWatermarkPolicy.normalize(dao.get(KEY_CALL_WATERMARK))
        val grantTime = CommsWatermarkPolicy.normalize(dao.get(KEY_CALL_SINCE))
        val from = CommsWatermarkPolicy.startFrom(stored, grantTime)
        if (from == null) {
            dao.set(AgentStateEntity(KEY_CALL_WATERMARK, CommsWatermarkPolicy.initialWatermark(stored, now)))
            dao.set(AgentStateEntity(KEY_CALL_SINCE, now))
            return@withLock
        }
        val events = mutableListOf<CommsEventEntity>()
        var newest: Long = from
        val seen = HashSet<CommsRowPolicy.Identity>()
        try {
            val cursor: Cursor? = context.contentResolver.query(
                CallLog.Calls.CONTENT_URI,
                arrayOf(
                    CallLog.Calls.NUMBER,
                    CallLog.Calls.DURATION,
                    CallLog.Calls.TYPE,
                    CallLog.Calls.DATE,
                    CallLog.Calls.PHONE_ACCOUNT_COMPONENT_NAME,
                ),
                "${CallLog.Calls.DATE} > ?",
                arrayOf(from.toString()),
                "${CallLog.Calls.DATE} ASC",
            )
            cursor?.use {
                while (it.moveToNext()) {
                    val ts = it.getLong(3)
                    newest = maxOf(newest, ts)
                    val type = it.getInt(2)
                    val duration = it.getLong(1)
                    val number = it.getString(0)
                    val component = it.getString(4)
                    val identity = CommsRowPolicy.Identity(ts, type, duration, component)
                    if (!CommsRowPolicy.shouldImport(number, component, identity, seen)) continue
                    seen.add(identity)
                    events.add(
                        CommsEventEntity(
                            type = "call",
                            number = number ?: "",
                            direction = callDirection(type),
                            durationSec = duration.toInt(),
                            timestamp = ts,
                        ),
                    )
                }
            }
        } catch (e: SecurityException) {
            // Race: the grant was revoked between the check and the query. Say it once, without a stack.
            if (!warnedCallPermission) {
                warnedCallPermission = true
                Log.i(TAG, "READ_CALL_LOG revoked mid-harvest; call harvesting paused")
            }
            return@withLock
        }
        persist(events, newest, KEY_CALL_WATERMARK, now)
    }

    /**
     * Reads Telephony.Sms rows newer than the stored watermark into Room (permission-guarded).
     *
     * Issue #229: the SMS stream follows the same start rule as calls — no watermark means collection
     * starts now and nothing is read. The `SecurityException` path is the one `harvestCalls()` had:
     * one INFO line, guarded by [warnedSmsPermission], never a stack.
     */
    private suspend fun harvestSms() = commsMutex.withLock {
        when (CommsAccessPolicy.decide(granted(Manifest.permission.READ_SMS), warnedSmsPermission)) {
            CommsAccessPolicy.Decision.HARVEST -> Unit
            CommsAccessPolicy.Decision.SKIP_QUIETLY -> return@withLock
            CommsAccessPolicy.Decision.SKIP_AND_REPORT -> {
                reportMissingSmsPermission()
                return@withLock
            }
        }
        val dao = db.agentStateDao()
        noteConsentState(dao)
        if (consent.isPaused()) return@withLock // ADR-0008 §3
        val now = System.currentTimeMillis()
        val stored = CommsWatermarkPolicy.normalize(dao.get(KEY_SMS_WATERMARK))
        val grantTime = CommsWatermarkPolicy.normalize(dao.get(KEY_SMS_SINCE))
        val from = CommsWatermarkPolicy.startFrom(stored, grantTime)
        if (from == null) {
            dao.set(AgentStateEntity(KEY_SMS_WATERMARK, CommsWatermarkPolicy.initialWatermark(stored, now)))
            dao.set(AgentStateEntity(KEY_SMS_SINCE, now))
            return@withLock
        }
        val events = mutableListOf<CommsEventEntity>()
        var newest: Long = from
        try {
            val cursor: Cursor? = context.contentResolver.query(
                Telephony.Sms.CONTENT_URI,
                arrayOf(
                    Telephony.Sms.ADDRESS,
                    Telephony.Sms.BODY,
                    Telephony.Sms.TYPE,
                    Telephony.Sms.DATE,
                ),
                "${Telephony.Sms.DATE} > ?",
                arrayOf(from.toString()),
                "${Telephony.Sms.DATE} ASC",
            )
            cursor?.use {
                while (it.moveToNext()) {
                    val ts = it.getLong(3)
                    newest = maxOf(newest, ts)
                    events.add(
                        CommsEventEntity(
                            type = "sms",
                            number = it.getString(0) ?: "",
                            direction = smsDirection(it.getInt(2)),
                            bodyPreview = (it.getString(1) ?: "").take(SMS_PREVIEW_CHARS),
                            timestamp = ts,
                        ),
                    )
                }
            }
        } catch (e: SecurityException) {
            // Race: the grant was revoked between the check and the query. Say it once, without a stack.
            if (!warnedSmsPermission) {
                warnedSmsPermission = true
                Log.i(TAG, "READ_SMS revoked mid-harvest; SMS harvesting paused")
            }
            return@withLock
        }
        persist(events, newest, KEY_SMS_WATERMARK, now)
    }

    private suspend fun persist(events: List<CommsEventEntity>, newest: Long, watermarkKey: String, now: Long) {
        if (events.isEmpty()) {
            if (newest > 0L) db.agentStateDao().set(AgentStateEntity(watermarkKey, newest))
            return
        }
        val dao = db.commsEventDao()
        for (event in events) {
            dao.insert(event)
            maybeAlertUnknownContact(event.number, now)
        }
        db.agentStateDao().set(AgentStateEntity(watermarkKey, newest))
    }

    /** Uploads all buffered comms events; the Room table is cleared only on success. */
    override suspend fun flush() {
        val deviceId = settings.deviceId() ?: return
        // Issue #229: the same mutex as a harvest — otherwise `all()` + `clear()` can drop a row a
        // concurrent harvest inserted between them, and its watermark has already moved past it.
        commsMutex.withLock {
            val dao = db.commsEventDao()
            noteConsentState(db.agentStateDao())
            if (consent.isPaused()) {
                dao.clear() // ADR-0008 §3: withdrawal stops collection; nothing buffered may be uploaded later
                return@withLock
            }
            val events = dao.all()
            if (events.isEmpty()) return@withLock
            val batch = ActivityEventBatchDto(
                events = events.map { e ->
                    ActivityEventDto(
                        type = e.type,
                        payload = when (e.type) {
                            "call" -> mapOf(
                                "number" to e.number,
                                "durationSec" to e.durationSec,
                                "direction" to e.direction,
                            )
                            else -> mapOf(
                                "number" to e.number,
                                "bodyPreview" to (e.bodyPreview ?: ""),
                            )
                        },
                    )
                },
            )
            try {
                api.postActivityEvents(deviceId, batch)
                dao.clear()
            } catch (e: CancellationException) {
                throw e // NOTE: never swallow coroutine cancellation
            } catch (e: Exception) {
                Log.w(TAG, "comms flush failed; events kept for next round", e)
            }
        }
    }

    /** Feature #27: at most one unknown_contact alert per hour per unknown number (allowlist non-empty). */
    private suspend fun maybeAlertUnknownContact(number: String, nowMs: Long) {
        val digits = Allowlist.normalizeNumber(number)
        if (digits.length < Allowlist.MIN_NUMBER_DIGITS) return
        if (!Allowlist.isUnknownContact(number, rules.contactAllowlist())) return
        val last = lastAlertAt[digits]
        if (last != null && nowMs - last < ALERT_THROTTLE_MS) return
        lastAlertAt[digits] = nowMs
        val childId = settings.childId() ?: return
        runCatching {
            api.postInternalAlert(
                AlertDto(
                    childId = childId,
                    deviceId = settings.deviceId(),
                    severity = "info",
                    category = "unknown_contact",
                    title = "Unknown contact",
                    body = "Child contacted/received from $digits",
                    metadata = mapOf("contact" to digits),
                ),
            )
        }
    }

    private fun callDirection(type: Int): String = when (type) {
        CallLog.Calls.INCOMING_TYPE -> "incoming"
        CallLog.Calls.OUTGOING_TYPE -> "outgoing"
        CallLog.Calls.MISSED_TYPE -> "missed"
        else -> "other"
    }

    private fun smsDirection(type: Int): String = when (type) {
        Telephony.Sms.MESSAGE_TYPE_INBOX -> "incoming"
        Telephony.Sms.MESSAGE_TYPE_SENT -> "outgoing"
        else -> "other"
    }

    companion object {
        private const val TAG = "CommsLogger"

        /** In-process flush cadence (the 15-min TelemetryWorker is the reboot-proof backstop). */
        const val FLUSH_PERIOD_MS: Long = 5 * 60_000L

        /** SMS body preview length. */
        const val SMS_PREVIEW_CHARS: Int = 120

        /** Min delay between unknown_contact alerts for the same number. */
        const val ALERT_THROTTLE_MS: Long = 60 * 60_000L

        private const val KEY_CALL_WATERMARK = "comms_call_watermark"
        private const val KEY_SMS_WATERMARK = "comms_sms_watermark"

        /** Issue #229: when each stream was first allowed; a read never goes below this. */
        private const val KEY_CALL_SINCE = "comms_call_since"
        private const val KEY_SMS_SINCE = "comms_sms_since"

        /** Issue #229: a withdrawal was observed; the next grant restarts the window at the grant. */
        private const val KEY_CONSENT_EPOCH = "comms_consent_epoch"
    }
}
