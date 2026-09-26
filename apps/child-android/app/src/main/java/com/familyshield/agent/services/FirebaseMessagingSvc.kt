package com.familyshield.agent.services

import com.google.firebase.messaging.FirebaseMessagingService
import com.google.firebase.messaging.RemoteMessage
import com.familyshield.agent.commands.CommandDispatcher
import com.familyshield.agent.data.AgentSettings
import com.familyshield.agent.network.ApiService
import com.familyshield.agent.network.dto.PushTokenDto
import dagger.hilt.android.AndroidEntryPoint
import javax.inject.Inject
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch

@AndroidEntryPoint
class FirebaseMessagingSvc : FirebaseMessagingService() {
    @Inject lateinit var dispatcher: CommandDispatcher
    @Inject lateinit var api: ApiService
    @Inject lateinit var settings: AgentSettings

    private val scope = CoroutineScope(Dispatchers.IO)

    override fun onMessageReceived(msg: RemoteMessage) {
        val type = msg.data["type"] ?: return
        dispatcher.dispatch(type, msg.data)
    }

    override fun onNewToken(token: String) {
        super.onNewToken(token)
        // NOTE: FirebaseMessagingService has no goAsync(); the upload is best-effort fire-and-forget.
        scope.launch {
            runCatching {
                settings.deviceId()?.let { deviceId ->
                    api.postPushToken(deviceId, PushTokenDto(token))
                }
            }
        }
    }
}
