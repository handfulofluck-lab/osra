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

    /**
     * Issue #257 review: a counter that rises once per observed withdrawal, and the wall-clock moment
     * the phone learned consent came back.
     *
     * The comms watermark reset used to run at the first *harvest* after a re-grant. That missed a
     * pause shorter than the 5-minute loop (nothing looked while paused, so the pause was never
     * recorded — the paused-window rows leaked afterwards) and dropped the first call after a re-grant
     * (the resetting harvest read nothing, including the call that triggered it).
     *
     * Recording the transition here — where the flag actually flips — fixes both: the epoch moves the
     * instant the withdrawal is seen, and the restart point is when the phone learned of the re-grant,
     * not when a later harvest noticed. In memory first, so a harvest that reads `isPaused() == false`
     * also sees the new values without waiting for the DataStore write.
     */
    @Volatile private var pauseEpoch: Long = settings.consentPauseEpochSync()
    @Volatile private var resumedAtMs: Long = settings.consentResumedAtSync()

    /** True while the parent has withdrawn consent; collection and enforcement must stop. */
    fun isPaused(): Boolean = paused

    /** Counts observed withdrawals; unchanged since the last one is what tells a harvest to reset. */
    fun pauseEpoch(): Long = pauseEpoch

    /** When the phone learned consent was granted again; the watermarks restart from here. */
    fun resumedAtMs(): Long = resumedAtMs

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
        if (next) pauseEpoch += 1 else resumedAtMs = System.currentTimeMillis()
        paused = next
        Log.i(TAG, if (next) "consent withdrawn — monitoring paused ($reason)" else "consent active — monitoring resumed ($reason)")
        scope.launch { runCatching { settings.saveConsentState(next, pauseEpoch, resumedAtMs) } }
    }

    private companion object {
        const val TAG = "ConsentState"
    }
}
