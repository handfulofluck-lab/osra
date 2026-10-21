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

    /** Issue #260: say the clock-back re-anchor once, not every five minutes. */
    @Volatile private var warnedClockBack = false

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
        // Issue #260: the call stream is watermarked by `_ID`; a reset clears that key (0 = "set,
        // nothing read yet") and the next harvest anchors at the re-grant with `newestCallIdEndedBy`
        // before it reads anything (#269 review: the old comment claimed the anchor branch handled
        // this, but that branch needs a missing key, not a zero one).
        dao.set(AgentStateEntity(KEY_CALL_ID_WATERMARK, 0L))
        // Issue #264 review (D2): a withdrawal round trip also re-opens the SMS window, and the read
        // floor is `resumedAtMs` — which can still be on the forward clock. Recording the newest id here
        // is what stops a text that arrived during the withdrawal from being imported as "future".
        dao.set(AgentStateEntity(KEY_SMS_ID_FLOOR, newestSmsId()))
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
        // Issue #260: the call watermark is `CallLog._ID`, not `DATE`. `DATE` is when a call *started*
        // but the row is written when it *ends*, so a long call that ends after a shorter call answered
        // during it carries the older `DATE`: the short call raised the watermark past it and the long
        // call was never read. `_ID` is monotonic and never reused. `null` means "never set" (a fresh
        // install, or an upgrade from a build with no id watermark); `0` means "set, nothing read yet",
        // which a consent reset writes -- and either state must be anchored before any row is offered,
        // because the query has no `DATE` predicate left to bound it (#269 review).
        val storedId: Long? = dao.get(KEY_CALL_ID_WATERMARK)
        val legacyDate = CommsWatermarkPolicy.normalize(dao.get(KEY_CALL_WATERMARK))
        var grantTime = CommsWatermarkPolicy.normalize(dao.get(KEY_CALL_SINCE))
        // Issue #260 review: a grant time in the future hides every call, permanently. The floor is read
        // twice per harvest and `now` moves, so clamping at read time keeps excluding a call made two
        // minutes ago -- and the id watermark never advances past it. Re-anchor the stored floor once
        // instead. The device can reach this state honestly (a clock set forward, then consent
        // re-granted), so it is repaired rather than treated as tampering.
        if (CommsWatermarkPolicy.isClockBack(grantTime, now)) {
            dao.set(AgentStateEntity(KEY_CALL_SINCE, now))
            grantTime = now
        }
        val dateFloor = grantTime ?: 0L
        if (storedId == null) {
            // First harvest, and the one upgrade path from the `DATE` watermark. The ceiling is the grant
            // when there is one and **now** on a fresh install: with no `DATE` predicate in the query, an
            // anchor of 0 would offer the phone's whole call log to `shouldReadCall`, and every call that
            // ended before the grant counts as "clock set back" and would be read (#269 review, D1).
            val ceiling = maxOf(legacyDate ?: 0L, grantTime ?: now)
            dao.set(AgentStateEntity(KEY_CALL_ID_WATERMARK, newestCallIdEndedBy(ceiling)))
            dao.set(AgentStateEntity(KEY_CALL_WATERMARK, ceiling))
            if (grantTime == null) dao.set(AgentStateEntity(KEY_CALL_SINCE, now))
            return@withLock
        }
        // A consent reset writes `0` into the id watermark and keeps a real floor, and so does a phone
        // that stored 0 under the old `DATE` predicate. With no predicate to stop it, `_ID > 0` is the
        // whole log, so anchor at the floor first and then read in the same round — the call that
        // triggered the harvest has to survive (#257).
        var fromId = storedId
        if (fromId == 0L && dateFloor > 0L) {
            fromId = newestCallIdEndedBy(dateFloor)
            dao.set(AgentStateEntity(KEY_CALL_ID_WATERMARK, fromId))
        }
        val events = mutableListOf<CommsEventEntity>()
        var newest: Long = fromId
        val seen = HashSet<CommsRowPolicy.Identity>()
        try {
            val cursor: Cursor? = context.contentResolver.query(
                CallLog.Calls.CONTENT_URI,
                arrayOf(
                    CallLog.Calls._ID,
                    CallLog.Calls.NUMBER,
                    CallLog.Calls.DURATION,
                    CallLog.Calls.TYPE,
                    CallLog.Calls.DATE,
                    CallLog.Calls.PHONE_ACCOUNT_COMPONENT_NAME,
                ),
                "${CallLog.Calls._ID} > ?",
                arrayOf(fromId.toString()),
                "${CallLog.Calls._ID} ASC",
            )
            cursor?.use {
                while (it.moveToNext()) {
                    val rowId = it.getLong(0)
                    newest = maxOf(newest, rowId)
                    val number = it.getString(1)
                    val duration = it.getLong(2)
                    val type = it.getInt(3)
                    val ts = it.getLong(4)
                    val component = it.getString(5)
                    // Issue #264 (F2): the floor is applied per row, not in the query, because a call
                    // made with the clock set back has an older `DATE` and a *higher* id -- see
                    // [CommsWatermarkPolicy.shouldReadCall] for which way each case goes.
                    if (!CommsWatermarkPolicy.shouldReadCall(ts, duration, dateFloor)) continue
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
        persist(events, newest, KEY_CALL_ID_WATERMARK, now)
    }

    /**
     * Issue #264 review (D2): the newest `Telephony.Sms._ID`, or -1 when it cannot be read.
     *
     * Recorded when the SMS read floor is set (first harvest, consent reset) so the future branch can
     * tell a text that arrived after collection started from one that was already there. -1 is "not
     * known yet" and the harvest resolves it before its first use; it is never treated as "no floor",
     * because fail-open is what imported the withdrawn window.
     */
    private fun newestSmsId(): Long {
        return try {
            context.contentResolver.query(
                Telephony.Sms.CONTENT_URI,
                arrayOf(Telephony.Sms._ID),
                null,
                null,
                "${Telephony.Sms._ID} DESC",
            )?.use { if (it.moveToFirst()) it.getLong(0) else 0L } ?: -1L
        } catch (e: SecurityException) {
            -1L
        }
    }

    /**
     * Issue #264 (F2): the newest `CallLog._ID` whose call **ended** at or before [ceilingEnd], or 0.
     *
     * Used by the first harvest after an upgrade or a consent reset, to anchor at what the previous rule
     * already covered so nothing is re-read. Anchoring on `DATE` (as #260 did) was wrong by one direction:
     * rows are written when a call ends, so a call that started before the ceiling and ended after it has
     * a *lower* `DATE` than its position suggests. Iterating ids downwards and stopping at the first row
     * whose span ends by the ceiling puts the anchor where the window really closes.
     */
    private fun newestCallIdEndedBy(ceilingEnd: Long): Long {
        if (ceilingEnd <= 0L) return 0L
        return try {
            context.contentResolver.query(
                CallLog.Calls.CONTENT_URI,
                arrayOf(CallLog.Calls._ID, CallLog.Calls.DATE, CallLog.Calls.DURATION),
                "${CallLog.Calls.DATE} <= ?",
                arrayOf(ceilingEnd.toString()),
                "${CallLog.Calls._ID} DESC",
            )?.use { cursor ->
                while (cursor.moveToNext()) {
                    val endedAt = cursor.getLong(1) + cursor.getLong(2) * 1000L
                    if (endedAt <= ceilingEnd) return cursor.getLong(0)
                }
                0L
            } ?: 0L
        } catch (e: SecurityException) {
            0L
        }
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
        var grantTime = CommsWatermarkPolicy.normalize(dao.get(KEY_SMS_SINCE))
        // Issue #260 review: a grant time in the future hides every message for as long as it is stored,
        // because the floor is re-read with a newer `now` each harvest and never lets the row through.
        // Re-anchor it once, exactly as the watermark below is re-anchored.
        if (CommsWatermarkPolicy.isClockBack(grantTime, now)) {
            dao.set(AgentStateEntity(KEY_SMS_SINCE, now))
            grantTime = now
        }
        // Issue #260: SMS keeps a DATE watermark (the SMS table may reuse ids, and messages are written
        // in time order), so it needs the clock guard the call stream no longer does. A watermark more
        // than the skew in the future means the clock moved back: re-anchor to now and read nothing this
        // round. One window is lost; without this, every message afterwards is lost instead.
        if (CommsWatermarkPolicy.isClockBack(stored, now)) {
            dao.set(AgentStateEntity(KEY_SMS_WATERMARK, now))
            if (!warnedClockBack) {
                warnedClockBack = true
                Log.i(TAG, "SMS watermark was in the future (clock moved back); re-anchored to now")
            }
            return@withLock
        }
        val from = CommsWatermarkPolicy.startFrom(stored, grantTime)
        if (from == null) {
            dao.set(AgentStateEntity(KEY_SMS_WATERMARK, CommsWatermarkPolicy.initialWatermark(stored, now)))
            dao.set(AgentStateEntity(KEY_SMS_SINCE, now))
            // Issue #264 review (D2): the window opens here, so the newest id at this moment is the
            // boundary between "already there" and "arrived after collection was allowed".
            dao.set(AgentStateEntity(KEY_SMS_ID_FLOOR, newestSmsId()))
            return@withLock
        }
        val events = mutableListOf<CommsEventEntity>()
        var newest: Long = from
        // Issue #264 (F1): identities of future-dated rows already imported, pruned to those the
        // watermark has not reached yet. Loaded once per harvest, written back only if it changed.
        val loadedFutureSeen = settings.futureSmsSeen()
        var futureSeen = CommsFutureSmsPolicy.prune(loadedFutureSeen, from)
        var futureSeenChanged = futureSeen != loadedFutureSeen
        // Issue #264 review (D2): the newest SMS id at the moment collection was allowed. -1 means it
        // could not be read then, so it is resolved to the newest id visible now -- before the query,
        // which is what keeps a text that predates the window from being imported.
        var smsIdFloor: Long = dao.get(KEY_SMS_ID_FLOOR) ?: -1L
        if (smsIdFloor < 0L) {
            smsIdFloor = newestSmsId()
            dao.set(AgentStateEntity(KEY_SMS_ID_FLOOR, smsIdFloor))
        }
        try {
            val cursor: Cursor? = context.contentResolver.query(
                Telephony.Sms.CONTENT_URI,
                arrayOf(
                    Telephony.Sms._ID,
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
                    val rowId = it.getLong(0)
                    val address = it.getString(1) ?: ""
                    val ts = it.getLong(4)
                    val entry = CommsFutureSmsPolicy.entry(ts, rowId, CommsFutureSmsPolicy.digest(address))
                    val tracked = CommsFutureSmsPolicy.isTracked(futureSeen, entry)
                    // Issue #264 (F1): a row dated beyond the skew is imported **once**, then remembered
                    // by `date|id|digest` until the watermark passes its date. Before this it was skipped
                    // on every harvest and reached the parent when the real date caught up — up to a
                    // year. The watermark still does not move, because that would hide every honest
                    // message behind it; the server bounds the reported time (#263).
                    if (CommsWatermarkPolicy.isFutureRow(ts, now)) {
                        if (tracked) continue
                        // #264 review (D2): a row that existed before collection was allowed is not ours
                        // to import, even though its future date passes the read floor. Remember it
                        // without importing, so the tracked check below keeps it out when its date comes.
                        if (CommsFutureSmsPolicy.shouldImportFuture(rowId, smsIdFloor)) {
                            events.add(
                                CommsEventEntity(
                                    type = "sms",
                                    number = address,
                                    direction = smsDirection(it.getInt(3)),
                                    bodyPreview = (it.getString(2) ?: "").take(SMS_PREVIEW_CHARS),
                                    timestamp = ts,
                                ),
                            )
                        }
                        futureSeen = CommsFutureSmsPolicy.remember(futureSeen, entry)
                        futureSeenChanged = true
                        continue
                    }
                    // #264 review (D1): the set is consulted here too. Without this, a row imported while
                    // its date was ahead was imported again when the real date arrived — a year later, and
                    // `prune` could not prevent it because the watermark only reaches the date by reading
                    // the row. The watermark still advances, so the entry is pruned on the next harvest.
                    newest = maxOf(newest, ts)
                    if (tracked) continue
                    events.add(
                        CommsEventEntity(
                            type = "sms",
                            number = address,
                            direction = smsDirection(it.getInt(3)),
                            bodyPreview = (it.getString(2) ?: "").take(SMS_PREVIEW_CHARS),
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
        persist(events, CommsWatermarkPolicy.nextWatermark(newest, now), KEY_SMS_WATERMARK, now)
        // Issue #264 (F1): recording the identities is what makes "import once" true rather than "import
        // every five minutes". It is written after the rows are queued so a crash between the two loses
        // one duplicate at worst, never a message.
        if (futureSeenChanged) settings.setFutureSmsSeen(futureSeen)
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
                        // Issue #260: send the row's own time. The server stamps "now" when this is
                        // absent, which dated a whole batch to the flush and made an offline phone
                        // report hours of calls at the moment it reconnected.
                        ts = CommsEventTimestamps.isoUtc(e.timestamp),
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

        /** The newest `CallLog._ID` already read (issue #260); `DATE` is no longer the call watermark. */
        private const val KEY_CALL_ID_WATERMARK = "comms_call_id_watermark"

        /** Kept for the one-time upgrade from the `DATE` watermark and as the consent-reset ceiling. */
        private const val KEY_CALL_WATERMARK = "comms_call_watermark"
        private const val KEY_SMS_WATERMARK = "comms_sms_watermark"

        /** Issue #229: when each stream was first allowed; a read never goes below this. */
        private const val KEY_CALL_SINCE = "comms_call_since"
        private const val KEY_SMS_SINCE = "comms_sms_since"

        /** Issue #264 (F1/D2): the newest SMS id when the SMS window opened, and the future rows seen. */
        private const val KEY_SMS_ID_FLOOR = "comms_sms_id_floor"

        /** Issue #229: a withdrawal was observed; the next grant restarts the window at the grant. */
        private const val KEY_CONSENT_EPOCH = "comms_consent_epoch"
    }
}
