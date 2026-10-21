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
