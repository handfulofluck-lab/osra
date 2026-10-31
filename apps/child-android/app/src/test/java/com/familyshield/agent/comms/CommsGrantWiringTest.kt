package com.familyshield.agent.comms

import java.io.File
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Issue #229: the decisions are pure and tested next door; this pins the wiring, because
 * `CommsLogger` needs Android and Room and cannot run in this JUnit-4 suite (there is no Robolectric
 * and no `androidTest` source set in this repository).
 *
 * What a green run here means: the source references the policy at each decision point and the three
 * call sites exist. What it does **not** mean: that a permission flip actually registers the observer
 * and runs a harvest on a device. That lifecycle is guarded, not executed — Robolectric would be the
 * honest harness for it, and adding it is a test-story decision for the reviewer, not smuggled in here.
 *
 * The shape (source text + `file:line`-style assertions in a JVM test) follows
 * `CommandDispatcherAckTest` and `LocationServiceStartSitesTest`.
 */
class CommsGrantWiringTest {

    private val capture = sourceFile("app/src/main/java/com/familyshield/agent/comms/CommsCapture.kt")
    private val noop = sourceFile("app/src/main/java/com/familyshield/agent/comms/NoopCommsCapture.kt")
    private val logger = sourceFile("app/src/full/java/com/familyshield/agent/comms/CommsLogger.kt")
    private val pairing = sourceFile("app/src/main/java/com/familyshield/agent/setup/PairingActivity.kt")

    @Test
    fun `the capture contract exposes the permission-change hook in both bindings`() {
        assertTrue(capture.contains("fun onPermissionsChanged()"))
        assertTrue(noop.contains("override fun onPermissionsChanged()"))
    }

    @Test
    fun `each observer has its own registration flag and goes through the policy`() {
        assertTrue(logger.contains("private var callObserverRegistered"))
        assertTrue(logger.contains("private var smsObserverRegistered"))
        assertTrue(logger.contains("CommsObserverPolicy.shouldRegister"))
        assertTrue("the call flag is only set by a successful registration", logger.contains("callObserverRegistered = true"))
        assertTrue("the SMS flag is only set by a successful registration", logger.contains("smsObserverRegistered = true"))
    }

    @Test
    fun `onPermissionsChanged is called from the grant result, onResume and the flush loop`() {
        assertTrue(
            "the permission result must retry the registration that failed at start",
            pairing.contains(") { commsCapture.onPermissionsChanged() }"),
        )
        val resume = pairing.substringAfter("override fun onResume()")
        assertTrue(
            "a grant made in Settings must be picked up when the launcher screen resumes",
            resume.substringBefore("private fun showLoading").contains("commsCapture.onPermissionsChanged()"),
        )
        assertTrue(
            "the 5-minute loop is the backstop when no activity resumes",
            logger.contains("runCatching { onPermissionsChanged() }"),
        )
        assertTrue(
            "the launcher screen injects the capture interface, not the full-build implementation",
            pairing.contains("@Inject lateinit var commsCapture: CommsCapture"),
        )
    }

    @Test
    fun `the first harvest is the watermark policy, not the old 0L default`() {
        assertTrue(logger.contains("CommsWatermarkPolicy.startFrom"))
        assertTrue(logger.contains("CommsWatermarkPolicy.initialWatermark"))
        assertTrue(logger.contains("KEY_CALL_SINCE") && logger.contains("KEY_SMS_SINCE"))
        assertFalse(
            "`get(key) ?: 0L` is exactly the bug: DATE > 0 reads the whole history",
            logger.contains("get(KEY_CALL_WATERMARK) ?: 0L") || logger.contains("get(KEY_SMS_WATERMARK) ?: 0L"),
        )
    }

    @Test
    fun `call rows go through the VoIP and duplicate policy`() {
        assertTrue(logger.contains("CommsRowPolicy.shouldImport"))
        assertTrue(
            "the component column is what distinguishes a Meet row from a private number",
            logger.contains("CallLog.Calls.PHONE_ACCOUNT_COMPONENT_NAME"),
        )
    }

    @Test
    fun `the SMS security exception logs once at INFO and never a stack`() {
        assertTrue(logger.contains("READ_SMS revoked mid-harvest; SMS harvesting paused"))
        assertTrue("the line is guarded by the one-per-process flag", logger.contains("if (!warnedSmsPermission) {"))
        assertFalse(
            "the old line logged the SecurityException with a stack at W",
            logger.contains("READ_SMS missing; sms harvest skipped"),
        )
        assertFalse(logger.contains("Log.w(TAG, \"READ_SMS"))
    }

    /**
     * Issue #257 review: the reset must be driven by the consent transition, not by a marker only a
     * harvest could write. A green run here means `ConsentState` records the epoch where the flag
     * flips and `CommsLogger` compares it; the phone rows are what prove the timing.
     */
    @Test
    fun `the consent transition is recorded where the flag flips, not by the harvest`() {
        val consentState = sourceFile("app/src/main/java/com/familyshield/agent/data/ConsentState.kt")
        assertTrue(
            "the epoch must advance at the flip, or a pause shorter than the loop is never recorded",
            consentState.contains("pauseEpoch += 1"),
        )
        assertTrue(
            "and the re-grant time must be stored at the flip too",
            consentState.contains("resumedAtMs = System.currentTimeMillis()"),
        )
        assertTrue(consentState.contains("fun pauseEpoch(): Long"))
        assertTrue(consentState.contains("fun resumedAtMs(): Long"))
        assertTrue(
            "both values are persisted with the flag, so a reboot keeps the epoch",
            consentState.contains("settings.saveConsentState(next, pauseEpoch, resumedAtMs)"),
        )
        assertTrue(
            "the logger compares epochs instead of writing its own paused marker",
            logger.contains("CommsConsentPolicy.resetTo("),
        )
        assertTrue(logger.contains("consent.resumedAtMs()"))
        assertFalse(
            "the harvest must no longer be the only writer of the pause marker",
            logger.contains("comms_consent_paused_seen"),
        )
    }

    /**
     * Issue #257 review: the two writes in `ConsentState.set` must happen in the safe order. A harvest
     * reads the epoch, then Room, then the flag; if the counter moved first, it could store the epoch as
     * applied during the withdrawal and the re-grant would skip the reset — the paused window leaks.
     */
    @Test
    fun `the flag is written before the counter, so a harvest cannot see a half transition`() {
        val consentState = sourceFile("app/src/main/java/com/familyshield/agent/data/ConsentState.kt")
        val withdrawal = consentState.indexOf("paused = true")
        val counter = consentState.indexOf("pauseEpoch += 1")
        val resumedAt = consentState.indexOf("resumedAtMs = System.currentTimeMillis()")
        val cleared = consentState.indexOf("paused = false")

        assertTrue("both writes are present", withdrawal > 0 && counter > 0 && resumedAt > 0 && cleared > 0)
        assertTrue(
            "on a withdrawal the flag must move first, or a harvest can see the new epoch while still active",
            withdrawal < counter,
        )
        assertTrue(
            "on a re-grant the time must move first, or a harvest can see paused == false with the old time",
            resumedAt < cleared,
        )
        assertTrue(
            "the dispatcher and the poll/rules threads can race on the check-then-set",
            consentState.contains("@Synchronized") && consentState.contains("private fun set("),
        )
    }

    /**
     * Issue #260: calls are watermarked by `_ID`, and the warning here is about what a green run means.
     * It does **not** mean a long call with a short waiting call is now read — no JVM test can insert
     * CallLog rows. It means the query is asked for ids above the stored id, in id order, with the grant
     * time still a `DATE` floor, so the case Claude measured on the phone can no longer be excluded by
     * the SQL. The phone row is what proves the behaviour.
     */
    @Test
    fun `the call harvest reads by id and applies the floor per row`() {
        assertTrue(
            "the watermark must be an id: DATE is when a call started, not when its row appeared",
            logger.contains("KEY_CALL_ID_WATERMARK"),
        )
        assertTrue(
            "the query must select _ID and order by it",
            logger.contains("CallLog.Calls._ID,") && logger.contains("\${CallLog.Calls._ID} > ?") &&
                logger.contains("\${CallLog.Calls._ID} ASC"),
        )
        assertTrue(
            "the floor is a per-row decision, because a clock set back gives an older DATE and a higher id",
            logger.contains("CommsWatermarkPolicy.shouldReadCall(ts, duration, dateFloor)"),
        )
        // The READ is by id. It is the one query below the anchor, and a DATE predicate there is what
        // lost the set-back call (#264 F2). The anchor query may use DATE (it now selects the
        // future-dated rows too), so the positive form is asserted rather than a negative on the file.
        assertTrue(
            "the call read must be by id, not by DATE",
            logger.contains("\"\${CallLog.Calls._ID} > ?\""),
        )
        assertTrue(
            "the anchor's rule lives in the pure policy, not inline (#264 withdrawal half)",
            logger.contains("newestCallIdEndedBy(") &&
                logger.contains("CallLog.Calls.DURATION") &&
                logger.contains("CommsWatermarkPolicy.countsAsBeforeAnchor("),
        )
        assertFalse("the DATE anchor is the bug it replaced", logger.contains("newestCallIdUpTo("))
    }

    /**
     * #485 review (F2): the policy can only anchor past a future-dated row that the anchor query
     * returns. Putting back the old `DATE <= ?` alone filters those rows out in SQL, so
     * `countsAsBeforeAnchor` never sees them and the withdrawal call is uploaded again, with every
     * policy row still green.
     *
     * Mutant: restore `"${CallLog.Calls.DATE} <= ?"` with one argument in `newestCallIdEndedBy` and this
     * row goes red.
     */
    @Test
    fun `the anchor query also selects future-dated rows, so the policy can anchor past them`() {
        val anchor = logger.substringAfter("private fun newestCallIdEndedBy(").substringBefore("private fun ")
        assertTrue(
            "both shapes must reach the policy: ended by the ceiling, or dated beyond now + skew",
            anchor.contains("\"(\${CallLog.Calls.DATE} <= ? OR \${CallLog.Calls.DATE} > ?)\""),
        )
        assertTrue(
            "the future bound is the real now plus the skew, not the ceiling",
            anchor.contains("val futureLimit = now + CommsWatermarkPolicy.CLOCK_SKEW_MS") &&
                anchor.contains("arrayOf(ceilingEnd.toString(), futureLimit.toString())"),
        )
    }

    /**
     * #269 review D1: with no `DATE` predicate left in the query, an id watermark of `0` offers the whole
     * call log, and `shouldReadCall` calls every pre-grant call "clock set back" and reads it. Both a
     * fresh install and a consent reset store `0`, so both paths must anchor before any row is offered.
     */
    @Test
    fun `a zero id watermark is anchored at the floor before the query can offer the whole log`() {
        assertTrue(
            "a fresh install anchors at now, not at 0",
            logger.contains("maxOf(legacyDate ?: 0L, grantTime ?: now)"),
        )
        assertTrue(
            "a stored 0 with a real floor anchors at that floor first",
            logger.contains("if (fromId == 0L && dateFloor > 0L)") &&
                logger.contains("fromId = newestCallIdEndedBy(dateFloor, now)"),
        )
        assertTrue(
            "and the query is bound to the anchored id, not to the stored one",
            logger.contains("arrayOf(fromId.toString())") &&
                !logger.contains("arrayOf(storedId.toString())"),
        )
        assertTrue("the round still reads what is left", logger.contains("var newest: Long = fromId"))
    }

    @Test
    fun `a grant time in the future is repaired in both harvests, not clamped`() {
        // #263 review: clamping with min(since, now) never lets the row through, because now advances
        // and the stored floor stays ahead of it. Both harvests must write now over the bad value.
        assertTrue(
            "calls: the stored floor is re-anchored",
            logger.contains("isClockBack(grantTime, now)") && logger.contains("dao.set(AgentStateEntity(KEY_CALL_SINCE, now))"),
        )
        assertTrue(
            "SMS: the stored floor is re-anchored",
            logger.contains("dao.set(AgentStateEntity(KEY_SMS_SINCE, now))"),
        )
        assertFalse(
            "read-time clamping is the bug, not the fix",
            logger.contains("clampedFloor"),
        )
    }

    @Test
    fun `the SMS stream keeps DATE but cannot be stopped by a clock set forward`() {
        assertTrue("SMS stays on its own watermark", logger.contains("KEY_SMS_WATERMARK"))
        assertTrue("the clock-back guard runs before the read", logger.contains("CommsWatermarkPolicy.isClockBack(stored, now)"))
        assertTrue("a future-dated message never advances the watermark", logger.contains("CommsWatermarkPolicy.isFutureRow(ts, now)"))
        assertTrue("the stored watermark is clamped to now", logger.contains("CommsWatermarkPolicy.nextWatermark(newest, now)"))
    }

    /**
     * #264 F1: a future-dated text is imported once and remembered, and the set is pruned as the
     * watermark passes. The pure rule is [CommsFutureSmsPolicyTest]; this pins that the harvest uses it.
     */
    @Test
    fun `a future-dated text is imported once and remembered, not skipped until its date arrives`() {
        val sms = logger.substringAfter("private suspend fun harvestSms()")
        assertTrue("the row id is selected, because an id alone is reused", sms.contains("Telephony.Sms._ID,"))
        assertTrue("the identity is recorded when the row is imported", sms.contains("CommsFutureSmsPolicy.entry("))
        assertTrue("and consulted before importing again", sms.contains("CommsFutureSmsPolicy.isTracked("))
        assertTrue("entries the watermark has passed are dropped", sms.contains("CommsFutureSmsPolicy.prune("))
        assertTrue("the set is bounded", sms.contains("CommsFutureSmsPolicy.remember("))
        assertTrue("and persisted after the rows are queued", sms.contains("settings.setFutureSmsSeen(futureSeen)"))
        assertTrue("the watermark still does not move to a future date", sms.contains("if (CommsWatermarkPolicy.isFutureRow(ts, now))"))
        assertFalse(
            "the old behaviour was to skip the row entirely",
            sms.contains("if (CommsWatermarkPolicy.isFutureRow(ts, now)) continue"),
        )
        // #264 review D1: the set is consulted in the normal branch too, or the row is imported again a
        // year later when its date arrives.
        assertTrue(
            "a tracked row is skipped once its date is no longer in the future",
            sms.contains("newest = maxOf(newest, ts)\n") && sms.contains("if (tracked) continue"),
        )
        // #264 review D2: an id floor separates "arrived after the window opened" from "was already there".
        assertTrue("a future row above the floor is imported", sms.contains("CommsFutureSmsPolicy.shouldImportFuture(rowId, smsIdFloor)"))
        assertTrue("the floor is resolved when unread", sms.contains("smsIdFloor = newestSmsId()"))
        assertTrue("and recorded where the SMS window opens", logger.contains("KEY_SMS_ID_FLOOR, newestSmsId()"))
    }

    @Test
    fun `a comms row is uploaded with its own time, not the flush time`() {
        assertTrue(
            "the DTO must carry ts, or the server stamps every row with the moment of the flush",
            logger.contains("ts = CommsEventTimestamps.isoUtc(e.timestamp)"),
        )
        val dto = sourceFile("app/src/main/java/com/familyshield/agent/network/dto/SocialDtos.kt")
        assertTrue(dto.contains("val ts: String? = null"))
    }

    @Test
    fun `a 428 on the command poll does not log a stack every minute`() {
        val service = sourceFile("app/src/main/java/com/familyshield/agent/services/LocationService.kt")
        val failure = service.substringAfter("consentState.onPollFailure(it)")
        assertTrue(
            "a withdrawal is the expected answer, not a warning",
            failure.substringBefore("Log.w(TAG, \"command poll failed\"").contains("ConsentPolicy.httpStatusOf(it) == 428"),
        )
        assertTrue(
            "every other failure still logs with its stack",
            failure.contains("Log.w(TAG, \"command poll failed\", it)"),
        )
    }

    private fun sourceFile(relative: String): String {
        var dir: File? = File(System.getProperty("user.dir")).absoluteFile
        while (dir != null) {
            val candidate = File(dir, relative)
            if (candidate.isFile) return candidate.readText()
            dir = dir.parentFile
        }
        throw AssertionError("could not find $relative from ${System.getProperty("user.dir")}")
    }
}
