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
import kotlinx.coroutines.runBlocking

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
     * starts on this callback's own thread instead of waiting for a WorkManager slot.
     *
     * It runs inside the callback on purpose (Claude's #322 review, 2026-10-23). FCM gives
     * `onMessageReceived` a short window and then applies background limits that can pause or
     * terminate the process **without an exception**. A poll launched on a separate scope returns from
     * this method immediately, so it runs *after* the window has closed: when FCM kills it, nothing
     * throws, `PushWakeHandler`'s fallback never fires, and the command waits for the periodic poll
     * (clamped to ~15 minutes). `runBlocking` on FCM's own worker thread — never the main thread —
     * keeps the poll inside the window, and the handler's 8 s budget bounds it well inside FCM's ~20 s.
     * The one-shot [CommandPollWorker.requestFetchNow] stays as the fallback for a poll that throws or
     * overruns: WorkManager outlives the process, which the callback does not.
     */
    override fun onMessageReceived(msg: RemoteMessage) {
        // Blocks FCM's worker thread (never the main thread) so the poll runs inside the handler window.
        runBlocking {
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
