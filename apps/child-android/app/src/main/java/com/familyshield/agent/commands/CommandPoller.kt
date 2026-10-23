package com.familyshield.agent.commands

import android.util.Log
import com.familyshield.agent.data.AgentSettings
import com.familyshield.agent.network.ApiService
import com.familyshield.agent.network.dto.PushTokenDto
import com.familyshield.agent.push.PushTokenUploadPolicy
import javax.inject.Inject
import javax.inject.Singleton

/**
 * One command fetch-and-dispatch pass: `GET /v1/devices/<id>/commands`, then each row dispatched and
 * acked through [CommandDispatcher]. This is **the one code path** Decision 2 (#319, 2026-10-23)
 * requires: the periodic [CommandPollWorker], the in-process push wake-up and the fallback worker all
 * call [pollOnce], so push and poll carry the same idempotent acks.
 *
 * The pass returns normally when there is nothing to do (not paired yet) and throws when the fetch
 * itself fails. What a failure means is the caller's decision: [CommandPollWorker] retries (up to three
 * attempts), and [com.familyshield.agent.push.PushWakeHandler] hands the failure to the one-shot worker.
 * A per-command failure is swallowed and logged here, exactly as the worker did before the extraction.
 */
@Singleton
class CommandPoller @Inject constructor(
    private val api: ApiService,
    private val settings: AgentSettings,
    private val dispatcher: CommandDispatcher,
) {

    /** Fetches and dispatches pending commands; per-command failures are swallowed and logged. */
    suspend fun pollOnce() {
        val deviceId = settings.deviceId()
            ?: return // NOTE: not paired yet — nothing to poll
        // Issue #319: the poll is also the retry path for a token minted before pairing. Runs before
        // the poll and never throws, so a failed token upload does not turn a good poll red (and a
        // failed poll still gets its token attempt on the next tick).
        uploadStoredPushToken(deviceId)
        val commands = api.getCommands(deviceId)
        commands.forEach { command ->
            runCatching {
                // NOTE: server payload values are untyped JSON; dispatcher takes strings.
                val payload = command.payload?.mapValues { (_, v) -> v?.toString() ?: "" } ?: emptyMap()
                dispatcher.dispatch(command.type, payload, command.id)
            }.onFailure { Log.w(TAG, "command '${command.type}' failed; swallowed", it) }
        }
    }

    /**
     * Issue #319: publishes the stored FCM token when [PushTokenUploadPolicy] says the server does not
     * have it yet. The marker is only advanced after the POST succeeds, so a 401/500/offline attempt is
     * retried on the next poll instead of being forgotten — the exact failure the old `onNewToken`-only
     * path had no recovery from.
     */
    private suspend fun uploadStoredPushToken(deviceId: String) {
        val stored = settings.pushToken() ?: return
        if (!PushTokenUploadPolicy.shouldUpload(stored, settings.uploadedPushToken(), deviceId)) return
        runCatching { api.postPushToken(deviceId, PushTokenDto(stored)) }
            .onSuccess { settings.recordUploadedPushToken(stored) }
            .onFailure { Log.w(TAG, "push token upload failed; retried on the next poll", it) }
    }

    companion object {
        private const val TAG: String = "CommandPoller"
    }
}
