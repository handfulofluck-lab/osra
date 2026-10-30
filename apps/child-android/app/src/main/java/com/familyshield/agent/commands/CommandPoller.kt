package com.familyshield.agent.commands

import android.util.Log
import com.familyshield.agent.data.AgentSettings
import com.familyshield.agent.network.DeviceRevoked
import com.familyshield.agent.network.dto.DeviceCommandDto
import com.familyshield.agent.network.DeviceUnlinker
import com.familyshield.agent.network.UnlinkPolicy
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
    private val unlinkPolicy: UnlinkPolicy,
    private val unlinker: DeviceUnlinker,
) {

    /** Fetches and dispatches pending commands; per-command failures are swallowed and logged. */
    suspend fun pollOnce() {
        val deviceId = settings.deviceId()
            ?: return // NOTE: not paired yet — nothing to poll
        // Issue #383: the poll is where the server says whether it still holds this phone's token, so
        // the response is read before anything is uploaded. The cadence call keeps the headers; the
        // body is what the dispatcher needs.
        val response = api.getCommandsWithCadence(deviceId)
        // Issue #465: a revoked device is not a transient failure to retry forever. The answer is read in
        // one place so both polls — this one and LocationService's — reach the same decision.
        if (onPollAnswer(response)) return
        if (!response.isSuccessful) throw retrofit2.HttpException(response)
        // Issue #319: the poll is also the retry path for a token minted before pairing. Never throws,
        // so a failed token upload does not turn a good poll red.
        syncPushToken(deviceId, response.headers()[PushTokenUploadPolicy.PUSH_TOKEN_HEADER])
        val commands = response.body().orEmpty()
        commands.forEach { command ->
            runCatching {
                // NOTE: server payload values are untyped JSON; dispatcher takes strings.
                val payload = command.payload?.mapValues { (_, v) -> v?.toString() ?: "" } ?: emptyMap()
                dispatcher.dispatch(command.type, payload, command.id)
            }.onFailure { Log.w(TAG, "command '${command.type}' failed; swallowed", it) }
        }
    }

    /**
     * Issue #465: the shared answer path for **every** poll, and the reason it is shared.
     *
     * On a normally paired phone the WorkManager run is skipped while `LocationService` is up
     * (`IdleCadence.workerShouldPoll`), and the service makes its own `getCommandsWithCadence` call. When
     * the answer was read only here, the `401 device_revoked` went to the service's own failure handler
     * and the phone stayed locked — the bug this whole change exists to fix. Both callers now go through
     * this method.
     *
     * Returns true when the poll must stop because the phone is no longer linked.
     */
    suspend fun onPollAnswer(response: retrofit2.Response<List<DeviceCommandDto>>): Boolean {
        if (response.isSuccessful) {
            // A good answer proves the phone is still linked, so a half-confirmation is dropped.
            unlinkPolicy.onLinked()
            return false
        }
        // One definite signal, and only one: a network error, a 5xx or a plain 401 a refresh could fix
        // must never unlink a phone, so the decision reads the status and the body's error code.
        val code = DeviceRevoked.codeFromBody(runCatching { response.errorBody()?.string() }.getOrNull())
        if (!DeviceRevoked.isRevoked(response.code(), code)) return false
        if (unlinkPolicy.onDeviceRevoked(System.currentTimeMillis())) unlinker.unlink()
        return true
    }

    /**
     * Issue #319: publishes the stored FCM token when [PushTokenUploadPolicy] says the server does not
     * have it yet. The marker is only advanced after the POST succeeds, so a 401/500/offline attempt is
     * retried on the next poll instead of being forgotten — the exact failure the old `onNewToken`-only
     * path had no recovery from.
     */
    suspend fun syncPushToken(deviceId: String, pushTokenHeader: String?) {
        val stored = settings.pushToken() ?: return
        val serverHasToken = PushTokenUploadPolicy.serverHasToken(pushTokenHeader)
        if (!PushTokenUploadPolicy.shouldUpload(stored, settings.uploadedPushToken(), deviceId, serverHasToken)) return
        runCatching { api.postPushToken(deviceId, PushTokenDto(stored)) }
            .onSuccess { settings.recordUploadedPushToken(stored) }
            .onFailure { Log.w(TAG, "push token upload failed; retried on the next poll", it) }
    }

    companion object {
        private const val TAG: String = "CommandPoller"
    }
}
