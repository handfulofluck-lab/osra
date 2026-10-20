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
 *   falls back to the cached set on a network error, so it has no failure signal to report).
 *
 * A handler that throws is a `failed` ack with `detail.reason = "command_failed"`. An unknown type
 * or an unparseable payload is [CommandOutcome.Ignored] and acks nothing, as designed before #231.
 * A null/blank command id acks nothing: the FCM path carries no durable row.
 */
sealed class CommandOutcome {
    /** The handler applied the effect (or, for rules_updated, accepted the asynchronous refresh). */
    data class Applied(val detail: Map<String, String> = emptyMap()) : CommandOutcome()

    /** The effect was not applied; [reason] becomes `detail.reason` in the history. */
    data class Refused(val reason: String) : CommandOutcome()

    /** Another component owns the ack: `locate_now` is acked by `LocationService` when a fix exists. */
    object Deferred : CommandOutcome()

    /** Nothing ran and nothing should be acked: unknown command type or malformed payload. */
    object Ignored : CommandOutcome()
}

/** Which source a `locate_now` fix came from; part of the `ok` ack's `detail`. */
enum class LocateFix(val wire: String) {
    FRESH("fresh"),
    CACHED("cached"),
}

object CommandAckPolicy {
    const val REASON_HANDLER_FAILED = "command_failed"
    const val REASON_LOCATION_UNAVAILABLE = "location_unavailable"

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
            CommandOutcome.Deferred, CommandOutcome.Ignored -> null
        }
    }

    /** Convenience for a synchronous dispatch: run once, ack at most once. */
    fun ackAfter(commandId: String?, handler: () -> CommandOutcome): CommandAckDto? =
        ackFor(commandId, outcomeOf(handler))

    /** `ok` only when a fix was obtained; `failed` with `location_unavailable` when there was none. */
    fun locateAck(commandId: String?, fix: LocateFix?): CommandAckDto? =
        ackFor(
            commandId,
            if (fix == null) {
                CommandOutcome.Refused(REASON_LOCATION_UNAVAILABLE)
            } else {
                CommandOutcome.Applied(mapOf("fix" to fix.wire))
            },
        )
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
