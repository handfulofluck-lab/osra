package com.familyshield.agent.commands

import java.time.Duration
import java.time.Instant
import java.time.OffsetDateTime
import java.time.format.DateTimeParseException

/**
 * ADR-0031 `show_reset_code`: the one command whose payload is a credential.
 *
 * The API sends `{requestId, parentName, code, expiresAt}` to every paired device of the family after
 * the parent clicks the mailbox link (`services/api/src/routes/auth.ts`, `mfa/reset/confirm`). The
 * payload is cleared server-side on ack, on command expiry and when the witness passes
 * (`services/api/src/lib/deviceCommands.ts`, `clearResetCodePayloads`). Nothing here stores it: the
 * notice lives in [ResetCodeState] for as long as the screen is up, and nowhere else.
 *
 * Pure Kotlin on purpose, so the JVM suite holds every validation row and the expiry decision without
 * an Android framework or a phone.
 */
data class ResetCodeNotice(
    /** Durable `DeviceCommand.id`, or null on the FCM path (which has no row to ack). */
    val commandId: String?,
    val requestId: String,
    val parentName: String,
    /** Exactly eight ASCII digits as sent; [ResetCodePolicy.formatCode] adds the display space. */
    val code: String,
    val expiresAt: Instant,
)

/** Parsing result for one payload; the reason becomes a `failed` ack's `detail.reason`. */
sealed class ResetCodeParse {
    data class Valid(val notice: ResetCodeNotice) : ResetCodeParse()
    data class Invalid(val reason: String) : ResetCodeParse()
}

/**
 * What `CommandDispatcher` should do with one `show_reset_code` delivery.
 *
 * [Withdraw] is the API taking the code back: `clearResetCodePayloads` sets `payload = {}`, so an
 * empty payload is the withdrawal signal on the next drain/redelivery, not a malformed command.
 */
sealed class ResetCodeDecision {
    data class Show(val notice: ResetCodeNotice) : ResetCodeDecision()
    data class Withdraw(val commandId: String?) : ResetCodeDecision()
    data class Refuse(val reason: String) : ResetCodeDecision()
}

/** How the notice ended; its wire value is the `ok` ack's `detail.screen`. */
enum class ResetCodeEnd(val wire: String) {
    EXPIRED("expired"),
    DISMISSED("dismissed"),
    WITHDRAWN("withdrawn"),

    /** A newer code replaced this one; the replaced row is acked so it does not sit `delivered`. */
    SUPERSEDED("superseded"),
}

/**
 * What the notice screen should do with the shared state. Distinguishing the two ways a notice can
 * vanish is the point: [EXPIRED] is copy ("ask your parent to start again"); [CLOSED] is silence,
 * because a withdrawal usually means the parent just used the code successfully.
 */
enum class ResetCodeView {
    /** A notice is in [ResetCodeState]; show it. */
    SHOWING,

    /** This screen watched the notice reach `expiresAt`; show the expired copy. */
    EXPIRED,

    /** The notice went for another reason (withdrawn, witness passed, request cancelled); close. */
    CLOSED,
}

object ResetCodePolicy {
    const val REASON_MISSING_REQUEST_ID = "missing_request_id"
    const val REASON_MISSING_CODE = "missing_code"
    const val REASON_MALFORMED_CODE = "malformed_code"
    const val REASON_MISSING_EXPIRES_AT = "missing_expires_at"
    const val REASON_MALFORMED_EXPIRES_AT = "malformed_expires_at"

    /** The payload is well-formed but its own `expiresAt` has passed; there is nothing to show. */
    const val REASON_EXPIRED = "reset_code_expired"

    /**
     * Nothing on the device can put the notice in front of the child: the overlay app-op, the bound
     * accessibility service and notifications are all unavailable.
     */
    const val REASON_SCREEN_UNAVAILABLE = "reset_code_screen_unavailable"

    private val EIGHT_DIGITS = Regex("^\\d{8}$")

    /**
     * The whole handler decision, kept out of [CommandDispatcher] so the JVM suite can hold the
     * malformed/expired/withdrawn cases.
     *
     * An **empty** payload is [ResetCodeDecision.Withdraw]. A payload that carries any key but no
     * usable one is [ResetCodeDecision.Refuse], so a server bug cannot silently look like a
     * withdrawal and leave a stale code on the screen.
     */
    fun decide(
        payload: Map<String, String>,
        commandId: String?,
        now: Instant,
        canShowScreen: Boolean,
    ): ResetCodeDecision {
        if (payload.isEmpty()) return ResetCodeDecision.Withdraw(commandId)
        return when (val parsed = parse(payload, commandId, now)) {
            is ResetCodeParse.Invalid -> ResetCodeDecision.Refuse(parsed.reason)
            is ResetCodeParse.Valid ->
                if (canShowScreen) ResetCodeDecision.Show(parsed.notice)
                else ResetCodeDecision.Refuse(REASON_SCREEN_UNAVAILABLE)
        }
    }

    /**
     * Strict on every field the credential needs. `parentName` is trimmed and may be **empty**: the
     * API sends `parent?.displayName ?? ""` and a display name is validated only as non-empty with no
     * trim, so a name of `" "` would otherwise make every phone refuse and the device witness could
     * never pass. The name is copy, not part of the credential — the screen falls back to generic
     * wording when it is blank.
     */
    fun parse(payload: Map<String, String>, commandId: String?, now: Instant): ResetCodeParse {
        val requestId = payload["requestId"]?.trim().orEmpty()
        if (requestId.isEmpty()) return ResetCodeParse.Invalid(REASON_MISSING_REQUEST_ID)

        val parentName = payload["parentName"]?.trim().orEmpty()

        val code = payload["code"]
        if (code == null) return ResetCodeParse.Invalid(REASON_MISSING_CODE)
        if (!EIGHT_DIGITS.matches(code)) return ResetCodeParse.Invalid(REASON_MALFORMED_CODE)

        val rawExpiresAt = payload["expiresAt"]
        if (rawExpiresAt.isNullOrBlank()) return ResetCodeParse.Invalid(REASON_MISSING_EXPIRES_AT)
        val expiresAt = parseInstant(rawExpiresAt) ?: return ResetCodeParse.Invalid(REASON_MALFORMED_EXPIRES_AT)

        if (isExpired(expiresAt, now)) return ResetCodeParse.Invalid(REASON_EXPIRED)

        return ResetCodeParse.Valid(ResetCodeNotice(commandId, requestId, parentName, code, expiresAt))
    }

    /**
     * The wire contract is `Date#toISOString()` (`…Z`), but ISO-8601 permits an offset. Both are
     * accepted; anything else is malformed. No lenient local-clock fallback: a payload without a
     * zone is not an instant and must not be guessed.
     */
    private fun parseInstant(value: String): Instant? =
        try {
            Instant.parse(value)
        } catch (_: DateTimeParseException) {
            try {
                OffsetDateTime.parse(value).toInstant()
            } catch (_: DateTimeParseException) {
                null
            }
        }

    /** `1234 5678`, so the code can be read aloud in two groups. */
    fun formatCode(code: String): String =
        if (code.length == 8) "${code.substring(0, 4)} ${code.substring(4)}" else code

    /**
     * The screen's three-way decision, kept out of the composable so the JVM suite holds it.
     *
     * [expiredHere] is set only by this screen's own expiry tick. A null notice with [expiredHere]
     * false means the notice was withdrawn — most often because the parent just typed the code — so
     * the screen closes rather than telling the child the code is invalid and to start again.
     */
    fun viewOf(notice: ResetCodeNotice?, expiredHere: Boolean): ResetCodeView = when {
        notice != null -> ResetCodeView.SHOWING
        expiredHere -> ResetCodeView.EXPIRED
        else -> ResetCodeView.CLOSED
    }

    /** `expiresAt` is inclusive of its own instant: at exactly `expiresAt` the code is gone. */
    fun isExpired(expiresAt: Instant, now: Instant): Boolean = !now.isBefore(expiresAt)

    /** Time left, never negative. */
    fun remaining(expiresAt: Instant, now: Instant): Duration {
        val left = Duration.between(now, expiresAt)
        return if (left.isNegative) Duration.ZERO else left
    }

    /**
     * Whole minutes left rounded **up**, so 90 seconds reads "2 minutes" and the screen never says
     * "0 minutes" while a code is still usable. Zero only when expired.
     */
    fun remainingMinutes(expiresAt: Instant, now: Instant): Int {
        val seconds = remaining(expiresAt, now).seconds
        if (seconds <= 0) return 0
        return ((seconds + 59) / 60).toInt()
    }

    /** The `ok` ack detail once the notice has ended; `ok` means the screen was shown. */
    fun ackDetail(end: ResetCodeEnd): Map<String, String> = mapOf("screen" to end.wire)
}
