package com.familyshield.agent.commands

import java.time.Duration
import java.time.Instant
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test

/**
 * ADR-0031's device half: the `show_reset_code` payload is a credential and the screen may only show
 * a code that is complete, current and attributable to a named parent.
 *
 * Every row here is pure Kotlin. The Activity itself is out of reach of the JVM suite (it needs the
 * Android framework), and the phone row is out of scope for this change.
 */
class ResetCodePolicyTest {

    private val now: Instant = Instant.parse("2026-10-23T12:00:00Z")
    private val expiresAt: Instant = now.plus(Duration.ofMinutes(10))

    private fun payload(
        requestId: String? = "req-1",
        parentName: String? = "Sam",
        code: String? = "12345678",
        expiresAt: String? = this.expiresAt.toString(),
    ): Map<String, String> = buildMap {
        requestId?.let { put("requestId", it) }
        parentName?.let { put("parentName", it) }
        code?.let { put("code", it) }
        expiresAt?.let { put("expiresAt", it) }
    }

    private fun invalidReason(payload: Map<String, String>): String =
        (ResetCodePolicy.parse(payload, "cmd-1", now) as ResetCodeParse.Invalid).reason

    @Before
    fun setUp() {
        ResetCodeState.clear()
    }

    @After
    fun tearDown() {
        ResetCodeState.clear()
    }

    @Test
    fun `a complete payload becomes the notice the screen renders`() {
        val parsed = ResetCodePolicy.parse(payload(), "cmd-1", now)

        val notice = (parsed as ResetCodeParse.Valid).notice
        assertEquals("cmd-1", notice.commandId)
        assertEquals("req-1", notice.requestId)
        assertEquals("Sam", notice.parentName)
        assertEquals("12345678", notice.code)
        assertEquals(expiresAt, notice.expiresAt)
    }

    @Test
    fun `parent and request ids are trimmed, and a blank parent name is kept, not refused`() {
        val notice = (ResetCodePolicy.parse(payload(requestId = "  req-1 ", parentName = " Sam "), null, now) as ResetCodeParse.Valid).notice
        assertEquals("req-1", notice.requestId)
        assertEquals("Sam", notice.parentName)

        // Finding 6: the API sends `displayName ?? ""` and a name of " " passes its validation, so a
        // blank name must not make every phone refuse and break the witness for that family. The
        // screen falls back to the unnamed copy; the name is not part of the credential.
        val unnamed = (ResetCodePolicy.parse(payload(parentName = "   "), "cmd-1", now) as ResetCodeParse.Valid).notice
        assertEquals("", unnamed.parentName)
        assertEquals("12345678", unnamed.code)
        assertEquals(
            "",
            (ResetCodePolicy.parse(payload(parentName = null), "cmd-1", now) as ResetCodeParse.Valid).notice.parentName,
        )
    }

    @Test
    fun `a payload without a request id is refused`() {
        assertEquals(ResetCodePolicy.REASON_MISSING_REQUEST_ID, invalidReason(payload(requestId = null)))
        assertEquals(ResetCodePolicy.REASON_MISSING_REQUEST_ID, invalidReason(payload(requestId = " ")))
    }

    @Test
    fun `a missing code is refused, not shown as an empty box`() {
        assertEquals(ResetCodePolicy.REASON_MISSING_CODE, invalidReason(payload(code = null)))
    }

    @Test
    fun `a code that is not exactly eight digits is refused`() {
        // Seven, nine, letters, and the display form the screen itself adds are all not the wire code.
        listOf("1234567", "123456789", "1234567a", "1234 5678", "12345678 ", "", "+1234567").forEach { bad ->
            assertEquals("code '$bad' must be refused", ResetCodePolicy.REASON_MALFORMED_CODE, invalidReason(payload(code = bad)))
        }
    }

    @Test
    fun `a code that expires exactly now is already expired`() {
        assertEquals(ResetCodePolicy.REASON_EXPIRED, invalidReason(payload(expiresAt = now.toString())))
    }

    @Test
    fun `an expiresAt in the past is refused`() {
        assertEquals(
            ResetCodePolicy.REASON_EXPIRED,
            invalidReason(payload(expiresAt = now.minusSeconds(1).toString())),
        )
    }

    @Test
    fun `a missing or malformed expiresAt is refused`() {
        assertEquals(ResetCodePolicy.REASON_MISSING_EXPIRES_AT, invalidReason(payload(expiresAt = null)))
        assertEquals(ResetCodePolicy.REASON_MISSING_EXPIRES_AT, invalidReason(payload(expiresAt = "  ")))
        listOf("tomorrow", "2026-10-23T12:10:00", "not-a-date").forEach { bad ->
            assertEquals("expiresAt '$bad' must be refused", ResetCodePolicy.REASON_MALFORMED_EXPIRES_AT, invalidReason(payload(expiresAt = bad)))
        }
    }

    @Test
    fun `an ISO-8601 offset expiry is accepted as the same instant`() {
        val parsed = ResetCodePolicy.parse(payload(expiresAt = "2026-10-23T14:10:00+02:00"), null, now)

        assertEquals(expiresAt, (parsed as ResetCodeParse.Valid).notice.expiresAt)
    }

    @Test
    fun `the display groups the code for reading aloud`() {
        assertEquals("1234 5678", ResetCodePolicy.formatCode("12345678"))
        assertEquals("0000 0001", ResetCodePolicy.formatCode("00000001"))
        assertEquals(
            "a malformed value is returned untouched so a bug is visible, not silently reflowed",
            "1234567",
            ResetCodePolicy.formatCode("1234567"),
        )
    }

    @Test
    fun `the expiry decision is inclusive of the encoded instant`() {
        assertFalse(ResetCodePolicy.isExpired(expiresAt, now))
        assertTrue(ResetCodePolicy.isExpired(expiresAt, expiresAt))
        assertTrue(ResetCodePolicy.isExpired(expiresAt, expiresAt.plusMillis(1)))
    }

    @Test
    fun `remaining time is never negative and rounds whole minutes up`() {
        assertEquals(10, ResetCodePolicy.remainingMinutes(expiresAt, now))
        assertEquals(2, ResetCodePolicy.remainingMinutes(now.plusSeconds(90), now))
        assertEquals(1, ResetCodePolicy.remainingMinutes(now.plusSeconds(30), now))
        assertEquals(0, ResetCodePolicy.remainingMinutes(now, now))
        assertEquals(0, ResetCodePolicy.remainingMinutes(now.minusSeconds(5), now))
        assertEquals(Duration.ZERO, ResetCodePolicy.remaining(now.minusSeconds(5), now))
    }

    @Test
    fun `a withdrawal closes the screen and only a real expiry shows the expired copy`() {
        // Finding 1, the behaviour itself: the screen is told apart by its own expiry flag.
        val notice = ResetCodePolicy.parse(payload(), "cmd-1", now).validNotice()

        assertEquals(ResetCodeView.SHOWING, ResetCodePolicy.viewOf(notice, expiredHere = false))
        assertEquals(ResetCodeView.SHOWING, ResetCodePolicy.viewOf(notice, expiredHere = true))
        assertEquals(
            "this screen watched it run out: the expired copy is right",
            ResetCodeView.EXPIRED,
            ResetCodePolicy.viewOf(null, expiredHere = true),
        )
        assertEquals(
            "withdrawn (witness passed, superseded, cancelled): the notice closes, it does not say 'start again'",
            ResetCodeView.CLOSED,
            ResetCodePolicy.viewOf(null, expiredHere = false),
        )
    }

    @Test
    fun `an empty payload is the API withdrawing the code, not a payload to show`() {
        val decision = ResetCodePolicy.decide(emptyMap(), "cmd-1", now, canShowScreen = true)

        assertEquals(ResetCodeDecision.Withdraw("cmd-1"), decision)
    }

    @Test
    fun `any malformed payload is a refusal with the reason that reaches the ack`() {
        assertEquals(
            ResetCodeDecision.Refuse(ResetCodePolicy.REASON_MALFORMED_CODE),
            ResetCodePolicy.decide(payload(code = "1234"), "cmd-1", now, canShowScreen = true),
        )
        assertEquals(
            ResetCodeDecision.Refuse(ResetCodePolicy.REASON_EXPIRED),
            ResetCodePolicy.decide(payload(expiresAt = now.minusSeconds(1).toString()), "cmd-1", now, canShowScreen = true),
        )
    }

    @Test
    fun `a valid code is refused when no background-launch path can show the screen`() {
        assertEquals(
            ResetCodeDecision.Refuse(ResetCodePolicy.REASON_SCREEN_UNAVAILABLE),
            ResetCodePolicy.decide(payload(), "cmd-1", now, canShowScreen = false),
        )
    }

    @Test
    fun `a valid code with a screen path is shown`() {
        val decision = ResetCodePolicy.decide(payload(), "cmd-1", now, canShowScreen = true)

        assertEquals("12345678", (decision as ResetCodeDecision.Show).notice.code)
    }

    @Test
    fun `a notification alone is a screen path`() {
        // Finding 4: the dispatcher passes `canShowScreen = canLaunch || canNotify`. A notification
        // needs no background-launch exemption, so a phone with the overlay app-op and accessibility
        // off still shows the code — refusing it there told the parent the phone could not.
        val canLaunch = false
        val canNotify = true

        assertEquals(
            "12345678",
            (ResetCodePolicy.decide(payload(), "cmd-1", now, canShowScreen = canLaunch || canNotify) as ResetCodeDecision.Show).notice.code,
        )
    }

    @Test
    fun `the end of a notice names how it ended in the ok ack`() {
        assertEquals(mapOf("screen" to "expired"), ResetCodePolicy.ackDetail(ResetCodeEnd.EXPIRED))
        assertEquals(mapOf("screen" to "dismissed"), ResetCodePolicy.ackDetail(ResetCodeEnd.DISMISSED))
        assertEquals(mapOf("screen" to "withdrawn"), ResetCodePolicy.ackDetail(ResetCodeEnd.WITHDRAWN))
        assertEquals("a replaced row reads like the others", mapOf("screen" to "superseded"), ResetCodePolicy.ackDetail(ResetCodeEnd.SUPERSEDED))
    }

    @Test
    fun `a newer notice replaces the current one and reports what it replaced`() {
        val first = ResetCodePolicy.parse(payload(requestId = "req-1"), "cmd-1", now).validNotice()
        val second = ResetCodePolicy.parse(payload(requestId = "req-2"), "cmd-2", now).validNotice()

        assertNull(ResetCodeState.show(first))
        assertEquals(first, ResetCodeState.show(second))
        assertEquals(second, ResetCodeState.notice.value)
    }

    @Test
    fun `an expiry timer for an old request cannot clear a newer code`() {
        val first = ResetCodePolicy.parse(payload(requestId = "req-1"), "cmd-1", now).validNotice()
        val second = ResetCodePolicy.parse(payload(requestId = "req-2"), "cmd-2", now).validNotice()
        ResetCodeState.show(first)
        ResetCodeState.show(second)

        assertNull("a stale timer must not tear down the newer notice", ResetCodeState.clearIfCurrent("req-1"))
        assertEquals(second, ResetCodeState.notice.value)
        assertEquals(second, ResetCodeState.clearIfCurrent("req-2"))
        assertNull(ResetCodeState.notice.value)
    }

    @Test
    fun `withdrawal clears the row it names and leaves an unrelated notice alone`() {
        val notice = ResetCodePolicy.parse(payload(requestId = "req-1"), "cmd-1", now).validNotice()
        ResetCodeState.show(notice)

        assertNull("an FCM delivery has no id and must not clear blindly", ResetCodeState.clearIfCommand(null))
        assertNull("another command cannot withdraw this code", ResetCodeState.clearIfCommand("cmd-other"))
        assertEquals(notice, ResetCodeState.notice.value)

        assertEquals(notice, ResetCodeState.clearIfCommand("cmd-1"))
        assertNull(ResetCodeState.notice.value)
    }

    private fun ResetCodeParse.validNotice(): ResetCodeNotice =
        (this as ResetCodeParse.Valid).notice
}
