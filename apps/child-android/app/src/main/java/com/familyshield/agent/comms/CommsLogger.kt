package com.familyshield.agent.comms

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
 * READ_SMS are runtime dangerous permissions — every access is guarded: missing permission logs
 * and skips (the observers stay registered and pick up once granted). NOTE: iOS has no equivalent
 * (no call-log/SMS API); the default-dialer role is intentionally NOT requested — log-only mode.
 * Feature #27: numbers not in the rule contactAllowlist (non-empty) raise a throttled
 * (1/hour/number) unknown_contact info alert.
 */
@Singleton
class CommsLogger @Inject constructor(
    @ApplicationContext private val context: Context,
    private val db: FamilyShieldDatabase,
    private val api: ApiService,
    private val settings: AgentSettings,
    private val rules: RuleRepository,
    private val consent: ConsentState,
) {
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    private val flushMutex = Mutex()
    private val lastAlertAt = HashMap<String, Long>()

    @Volatile private var started = false

    /** Registers the content observers and starts the periodic flush loop (idempotent). */
    fun start() {
        if (started) return
        started = true
        val resolver = context.contentResolver
        runCatching {
            resolver.registerContentObserver(CallLog.Calls.CONTENT_URI, true, callObserver)
        }.onFailure { Log.w(TAG, "call log observer unavailable", it) }
        runCatching {
            resolver.registerContentObserver(Telephony.Sms.CONTENT_URI, true, smsObserver)
        }.onFailure { Log.w(TAG, "sms observer unavailable", it) }
        scope.launch {
            while (isActive) {
                delay(FLUSH_PERIOD_MS)
                runCatching { flush() }
            }
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

    /** Reads CallLog rows newer than the stored watermark into Room (guarded by permission checks). */
    private suspend fun harvestCalls() {
        when (CommsAccessPolicy.decide(granted(Manifest.permission.READ_CALL_LOG), warnedCallPermission)) {
            CommsAccessPolicy.Decision.HARVEST -> Unit
            CommsAccessPolicy.Decision.SKIP_QUIETLY -> return
            CommsAccessPolicy.Decision.SKIP_AND_REPORT -> {
                warnedCallPermission = true
                Log.i(TAG, "READ_CALL_LOG not granted; call harvesting stays off until the parent grants it")
                return
            }
        }
        val watermark = db.agentStateDao().get(KEY_CALL_WATERMARK) ?: 0L
        val now = System.currentTimeMillis()
        val events = mutableListOf<CommsEventEntity>()
        var newest = watermark
        try {
            val cursor: Cursor? = context.contentResolver.query(
                CallLog.Calls.CONTENT_URI,
                arrayOf(
                    CallLog.Calls.NUMBER,
                    CallLog.Calls.DURATION,
                    CallLog.Calls.TYPE,
                    CallLog.Calls.DATE,
                ),
                "${CallLog.Calls.DATE} > ?",
                arrayOf(watermark.toString()),
                "${CallLog.Calls.DATE} ASC",
            )
            cursor?.use {
                while (it.moveToNext()) {
                    val ts = it.getLong(3)
                    newest = maxOf(newest, ts)
                    events.add(
                        CommsEventEntity(
                            type = "call",
                            number = it.getString(0) ?: "",
                            direction = callDirection(it.getInt(2)),
                            durationSec = it.getLong(1).toInt(),
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
            return
        }
        persist(events, newest, KEY_CALL_WATERMARK, now)
    }

    /** Reads Telephony.Sms rows newer than the stored watermark into Room (permission-guarded). */
    private suspend fun harvestSms() {
        when (CommsAccessPolicy.decide(granted(Manifest.permission.READ_SMS), warnedSmsPermission)) {
            CommsAccessPolicy.Decision.HARVEST -> Unit
            CommsAccessPolicy.Decision.SKIP_QUIETLY -> return
            CommsAccessPolicy.Decision.SKIP_AND_REPORT -> {
                warnedSmsPermission = true
                Log.i(TAG, "READ_SMS not granted; SMS harvesting stays off until the parent grants it")
                return
            }
        }
        val watermark = db.agentStateDao().get(KEY_SMS_WATERMARK) ?: 0L
        val now = System.currentTimeMillis()
        val events = mutableListOf<CommsEventEntity>()
        var newest = watermark
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
                arrayOf(watermark.toString()),
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
            // NOTE: READ_SMS not granted yet — skip this harvest; the observer retries later.
            Log.w(TAG, "READ_SMS missing; sms harvest skipped", e)
            return
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
    suspend fun flush() {
        val deviceId = settings.deviceId() ?: return
        flushMutex.withLock {
            val dao = db.commsEventDao()
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
    }
}
