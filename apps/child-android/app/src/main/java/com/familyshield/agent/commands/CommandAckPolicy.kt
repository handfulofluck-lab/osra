package com.familyshield.agent.commands

import com.familyshield.agent.network.dto.CommandAckDto

/**
 * Issue #231: a command that succeeds never acked, so its durable row stayed `delivered` and the
 * parent's `/v1/devices/:id/commands/history` said "the device has not confirmed it ran". This is
 * the one place a handler outcome becomes an ack, kept free of Android types so the JVM suite holds
 * it (`CommandDispatcher` itself needs a `Context`).
 *
 * **What `ok` means: the effect is observable to the parent**, not merely that `dispatch()` was
 * reached. Per command:
 * - synchronous handlers (lock, unlock, pause, resume, ring, stop_ring, sos_clear, pause_internet,
 *   resume_internet, bonus_time, consent_granted/consent_revoked) ack `ok` when they return;
 * - `locate_now` returns [CommandOutcome.Deferred] because starting the foreground service is not
 *   a fix: `LocationService` acks `ok` with `detail.fix = fresh|cached` only once a fix was obtained,
 *   and `failed` with `location_unavailable` when there was none;
 * - `wind_down` acks when the warning notification is posted and the timer is armed, not when the
 *   lock fires minutes later; `rules_updated` acks when the refresh has been accepted (`refresh()`
 *   falls back to the cached set on a network error, so it has no failure signal to report);
 * - `show_reset_code` returns [CommandOutcome.Deferred] while the notice is up: a display-time ack
 *   would clear the plaintext payload server-side before the parent read it and would stop the
 *   120-second redelivery that carries a withdrawal. `ResetCodeActivity` acks `ok` when the notice
 *   ends (`detail.screen = expired|dismissed`), and the dispatcher acks `withdrawn` when the API
 *   clears the payload.
 *
 * A handler that throws is a `failed` ack with `detail.reason = "command_failed"`. An unknown type
 * is `failed` with `unsupported_command` and an unparseable `bonus_time`/`wind_down` minutes payload
 * with `invalid_payload` (issue #231 review): a row left `delivered` forever is the defect #231
 * names, so no handler for a durable row is allowed to stay silent. A null/blank command id acks
 * nothing — the FCM path carries no durable row — and [CommandOutcome.Deferred] is acked later by
 * the component that owns it.
 */
sealed class CommandOutcome {
    /** The handler applied the effect (or, for rules_updated, accepted the asynchronous refresh). */
    data class Applied(val detail: Map<String, String> = emptyMap()) : CommandOutcome()

    /** The effect was not applied; [reason] becomes `detail.reason` in the history. */
    data class Refused(val reason: String) : CommandOutcome()

    /** Another component owns the ack: `locate_now` is acked by `LocationService` when a fix exists. */
    object Deferred : CommandOutcome()
}

/** Which source a `locate_now` fix came from; part of the `ok` ack's `detail`. */
enum class LocateFix(val wire: String) {
    FRESH("fresh"),
    CACHED("cached"),
}

object CommandAckPolicy {
    const val REASON_HANDLER_FAILED = "command_failed"
    const val REASON_LOCATION_UNAVAILABLE = "location_unavailable"

    /** Issue #231 review: a type this agent does not implement; the parent can ask for an update. */
    const val REASON_UNSUPPORTED_COMMAND = "unsupported_command"

    /** Issue #231 review: `bonus_time`/`wind_down` arrived without a parseable minutes value. */
    const val REASON_INVALID_PAYLOAD = "invalid_payload"

    /**
     * Runs [handler], turning a throw into [CommandOutcome.Refused] so the command is reported as
     * `failed` instead of crashing the poll loop. [onFailure] only logs; it does not change the ack.
     */
    fun outcomeOf(handler: () -> CommandOutcome, onFailure: (Exception) -> Unit = {}): CommandOutcome =
        try {
            handler()
        } catch (e: Exception) {
            onFailure(e)
            CommandOutcome.Refused(REASON_HANDLER_FAILED)
        }

    /** The ack for [commandId] and [outcome], or null when this outcome is not acked. */
    fun ackFor(commandId: String?, outcome: CommandOutcome): CommandAckDto? {
        if (commandId.isNullOrBlank()) return null
        return when (outcome) {
            is CommandOutcome.Applied ->
                CommandAckDto(status = "ok", detail = outcome.detail.ifEmpty { null })
            is CommandOutcome.Refused ->
                CommandAckDto(status = "failed", detail = mapOf("reason" to outcome.reason))
            CommandOutcome.Deferred -> null
        }
    }

    /** Convenience for a synchronous dispatch: run once, ack at most once. */
    fun ackAfter(commandId: String?, handler: () -> CommandOutcome): CommandAckDto? =
        ackFor(commandId, outcomeOf(handler))

    /**
     * `ok` only when a fix was obtained **and** the flush uploaded it; `failed` with
     * `location_unavailable` when there was no fix at all.
     *
     * Issue #231 review: `LocationService.flushPings()` used to swallow an upload failure, so a
     * `fresh` ack could go out while the point sat in the phone's buffer and the parent's map did
     * not move. With [uploaded] false and a fix in hand there is no observable effect, so the ack is
     * null and the row stays `delivered` for the 120 s re-offer. A missing fix is still acked
     * `failed`: there is nothing to upload, and leaving it silent would hide the refusal.
     */
    fun locateAck(commandId: String?, fix: LocateFix?, uploaded: Boolean): CommandAckDto? {
        if (fix != null && !uploaded) return null
        return ackFor(
            commandId,
            if (fix == null) {
                CommandOutcome.Refused(REASON_LOCATION_UNAVAILABLE)
            } else {
                CommandOutcome.Applied(mapOf("fix" to fix.wire))
            },
        )
    }
}

/**
 * Sends one ack and forgets it: a lost ack (offline, server asleep) leaves the row `delivered`,
 * which is the pre-#231 behaviour, so it is logged rather than retried in a loop. The command's
 * own outcome is unaffected. The lambda is injected so this is testable on the JVM.
 */
class CommandAckSender(
    private val send: suspend (commandId: String, ack: CommandAckDto) -> Unit,
    private val log: (String, Throwable) -> Unit,
) {
    suspend fun sendOnce(commandId: String, ack: CommandAckDto) {
        try {
            send(commandId, ack)
        } catch (e: Exception) {
            if (e is kotlinx.coroutines.CancellationException) throw e
            log("could not ack command $commandId (${ack.status}); it stays delivered", e)
        }
    }
}
