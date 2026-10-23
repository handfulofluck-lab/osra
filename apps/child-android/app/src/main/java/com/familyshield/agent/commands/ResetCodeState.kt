package com.familyshield.agent.commands

import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow

/**
 * The one `show_reset_code` notice the process is showing, shared by the dispatcher (which sets and
 * withdraws it) and [ResetCodeActivity] (which renders it and clears it at expiry).
 *
 * Deliberately **in memory only**. ADR-0031 claim 6 keeps the plaintext in the command payload and
 * nowhere else, so this object is never written to DataStore, Room, saved-instance state or a log.
 * Process death loses the notice; the server row is still `delivered` until the device acks or the
 * code expires, and a later redelivery can show it again.
 *
 * A newer request replaces the older notice: only one code is shown at a time, and the dispatcher
 * acks the replaced row `superseded` so it does not sit `delivered`.
 */
object ResetCodeState {

    private val _notice = MutableStateFlow<ResetCodeNotice?>(null)

    /** Observed by the screen; null means "no code" (never shown, withdrawn, expired or dismissed). */
    val notice: StateFlow<ResetCodeNotice?> = _notice.asStateFlow()

    /** Shows [next], returning the notice it replaced (the dispatcher acks that one superseded). */
    @Synchronized
    fun show(next: ResetCodeNotice): ResetCodeNotice? {
        val previous = _notice.value
        _notice.value = next
        return previous
    }

    /** Clears whatever is shown; used when the screen ends. */
    @Synchronized
    fun clear(): ResetCodeNotice? {
        val previous = _notice.value
        _notice.value = null
        return previous
    }

    /** Clears only the notice for [requestId], so a newer code is not torn down by an older timer. */
    @Synchronized
    fun clearIfCurrent(requestId: String): ResetCodeNotice? {
        val current = _notice.value ?: return null
        if (current.requestId != requestId) return null
        _notice.value = null
        return current
    }

    /**
     * Withdrawal path: the API cleared the payload and the same command row came back with `{}`.
     * A null [commandId] cannot be matched (the FCM path has no row id), so nothing is cleared
     * blindly — an unrelated empty delivery must not tear down a valid notice.
     */
    @Synchronized
    fun clearIfCommand(commandId: String?): ResetCodeNotice? {
        val current = _notice.value ?: return null
        if (commandId == null || current.commandId != commandId) return null
        _notice.value = null
        return current
    }
}
