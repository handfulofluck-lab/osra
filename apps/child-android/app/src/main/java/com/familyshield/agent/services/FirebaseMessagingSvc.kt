package com.familyshield.agent.services

import com.google.firebase.messaging.FirebaseMessagingService
import com.google.firebase.messaging.RemoteMessage
import com.familyshield.agent.commands.CommandPoller
import com.familyshield.agent.commands.CommandPollWorker
import com.familyshield.agent.data.AgentSettings
import com.familyshield.agent.network.ApiService
import com.familyshield.agent.network.dto.PushTokenDto
import com.familyshield.agent.push.PushTokenUploadPolicy
import com.familyshield.agent.push.PushWakeHandler
import dagger.hilt.android.AndroidEntryPoint
import javax.inject.Inject
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch

@AndroidEntryPoint
class FirebaseMessagingSvc : FirebaseMessagingService() {
    @Inject lateinit var poller: CommandPoller
    @Inject lateinit var api: ApiService
    @Inject lateinit var settings: AgentSettings

    private val scope = CoroutineScope(Dispatchers.IO)

    /**
     * A push is a **wake-up only** (Claude's Decision 2, #319, 2026-10-23): the message carries no
     * command type, payload or id, and this method reads none of them. Google must never see command
     * content — `show_reset_code` carries the parent's reset code and a location request carries the
     * timing of a family's day — and a stale or misdirected token then leaks nothing. There is
     * deliberately no `CommandDispatcher` here, so a data-dispatch path does not compile.
     *
     * The wake polls **in-process first** ([CommandPoller.pollOnce], the same call the periodic worker
     * makes). That is the lowest-latency path, which is what a `lock` needs: the HTTP round trip
     * starts on this callback's own coroutine instead of waiting for a WorkManager slot. The one-shot
     * [CommandPollWorker.requestFetchNow] is the **fallback**, because a `FirebaseMessagingService`
     * has no `goAsync()`: the process can be reclaimed the moment this callback returns, so a poll
     * that throws or cannot start is handed to WorkManager, which outlives the process.
     */
    override fun onMessageReceived(msg: RemoteMessage) {
        scope.launch {
            PushWakeHandler.onPushReceived(
                data = msg.data,
                poll = { poller.pollOnce() },
                fallback = { CommandPollWorker.requestFetchNow(applicationContext) },
            )
        }
    }

    override fun onNewToken(token: String) {
        super.onNewToken(token)
        // NOTE: FirebaseMessagingService has no goAsync(); the upload is best-effort fire-and-forget.
        scope.launch {
            runCatching {
                // Issue #319: persist first, conditionally upload second. A token minted before pairing
                // (the normal order on a fresh install) used to be dropped here forever, because the
                // upload was skipped when deviceId was null and FCM never re-delivers that token.
                settings.savePushToken(token)
                val deviceId = settings.deviceId() ?: return@launch
                if (!PushTokenUploadPolicy.shouldUpload(token, settings.uploadedPushToken(), deviceId)) {
                    return@launch
                }
                api.postPushToken(deviceId, PushTokenDto(token))
                settings.recordUploadedPushToken(token)
            }
        }
    }
}
