package com.familyshield.agent.commands

import android.content.Context
import android.util.Log
import androidx.work.CoroutineWorker
import androidx.work.WorkerParameters
import com.familyshield.agent.di.WorkerEntryPoint
import dagger.hilt.android.EntryPointAccessors

/** FCM-free command polling (§14.2): drains GET /v1/devices/<id>/commands and dispatches each. */
class CommandPollWorker(
    context: Context,
    params: WorkerParameters,
) : CoroutineWorker(context, params) {

    /** Fetches and dispatches pending commands; per-command failures are swallowed and logged. */
    override suspend fun doWork(): Result {
        val entryPoint = EntryPointAccessors.fromApplication(applicationContext, WorkerEntryPoint::class.java)
        val settings = entryPoint.agentSettings()
        val deviceId = settings.deviceId()
            ?: return Result.success() // NOTE: not paired yet — nothing to poll
        return try {
            val commands = entryPoint.apiService().getCommands(deviceId)
            val dispatcher = entryPoint.commandDispatcher()
            commands.forEach { command ->
                runCatching {
                    // NOTE: server payload values are untyped JSON; dispatcher takes strings.
                    val payload = command.payload?.mapValues { (_, v) -> v?.toString() ?: "" } ?: emptyMap()
                    dispatcher.dispatch(command.type, payload)
                }.onFailure { Log.w(TAG, "command '${command.type}' failed; swallowed", it) }
            }
            Result.success()
        } catch (e: Exception) {
            Log.w(TAG, "command poll failed", e)
            if (runAttemptCount < 3) Result.retry() else Result.failure()
        }
    }

    companion object {
        /** Unique work name for the periodic command poll. */
        const val WORK_NAME: String = "command_poll"

        private const val TAG: String = "CommandPollWorker"
    }
}
