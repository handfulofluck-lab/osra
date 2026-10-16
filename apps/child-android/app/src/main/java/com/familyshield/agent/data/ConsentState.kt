package com.familyshield.agent.data

import android.util.Log
import javax.inject.Inject
import javax.inject.Singleton
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.launch
import retrofit2.HttpException

/**
 * Pure decision table for the consent-pause lifecycle (ADR-0008 §3), kept free of Android types so
 * it is unit-testable. The agent pauses enforcement and *collection* when the parent withdraws
 * consent and resumes on re-grant; both signals arrive two ways — a queued command
 * (`consent_revoked` / `consent_granted`) and the HTTP status of the next rules/commands poll
 * (428 = paused, 2xx = active). The HTTP status is authoritative because the command is best-effort.
 */
object ConsentPolicy {
    const val COMMAND_REVOKED = "consent_revoked"
    const val COMMAND_GRANTED = "consent_granted"
    const val HTTP_PRECONDITION_REQUIRED = 428

    /** Next paused state after a device command of [type]; unknown commands leave the state unchanged. */
    fun afterCommand(paused: Boolean, type: String): Boolean = when (type) {
        COMMAND_REVOKED -> true
        COMMAND_GRANTED -> false
        else -> paused
    }

    /**
     * Next paused state after a rules/commands poll answered [httpStatus]. Only 428 and success
     * carry meaning: a 401/5xx/network failure says nothing about consent and must not flip state.
     */
    fun afterPoll(paused: Boolean, httpStatus: Int): Boolean = when {
        httpStatus == HTTP_PRECONDITION_REQUIRED -> true
        httpStatus in 200..299 -> false
        else -> paused
    }

    /** Extracts the HTTP status from a Retrofit failure, or null when the failure was not HTTP. */
    fun httpStatusOf(error: Throwable): Int? = (error as? HttpException)?.code()
}

/**
 * Process-wide consent-pause flag, persisted so a reboot while paused stays paused (AND-02 class).
 * Consulted by the accessibility monitor, social capture, comms logger, telemetry and location
 * upload: while [isPaused] every one of them is a no-op, and [RuleRepository.evaluate] answers ALLOW.
 */
@Singleton
class ConsentState @Inject constructor(
    private val settings: AgentSettings,
) {
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)

    @Volatile private var paused: Boolean = settings.consentPausedSync()

    /** True while the parent has withdrawn consent; collection and enforcement must stop. */
    fun isPaused(): Boolean = paused

    /** Applies a queued device command; returns true when the command was a consent command. */
    fun onCommand(type: String): Boolean {
        val next = ConsentPolicy.afterCommand(paused, type)
        val handled = type == ConsentPolicy.COMMAND_REVOKED || type == ConsentPolicy.COMMAND_GRANTED
        if (handled) set(next, "command $type")
        return handled
    }

    /** Applies the outcome of a rules/commands poll: 428 pauses, 2xx resumes, anything else is ignored. */
    fun onPollStatus(httpStatus: Int) {
        set(ConsentPolicy.afterPoll(paused, httpStatus), "poll status $httpStatus")
    }

    /** Convenience for `runCatching { api.x() }.onFailure { consent.onPollFailure(it) }`. */
    fun onPollFailure(error: Throwable) {
        ConsentPolicy.httpStatusOf(error)?.let { onPollStatus(it) }
    }

    private fun set(next: Boolean, reason: String) {
        if (next == paused) return
        paused = next
        Log.i(TAG, if (next) "consent withdrawn — monitoring paused ($reason)" else "consent active — monitoring resumed ($reason)")
        scope.launch { runCatching { settings.saveConsentPaused(next) } }
    }

    private companion object {
        const val TAG = "ConsentState"
    }
}
