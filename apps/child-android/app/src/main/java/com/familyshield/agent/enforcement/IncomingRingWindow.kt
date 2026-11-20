package com.familyshield.agent.enforcement

import android.os.SystemClock

/**
 * #828 / #851 / osra-security#33 / osra-security#43 / osra-security#49 / osra-security#50:
 * incoming cellular call exemption for the lock shade guard.
 *
 * Under a silent ringer or DND, `AudioManager.mode` stays `MODE_NORMAL` for the whole ring, so a
 * bounded 45-second upper-bound window from a trusted dialer / platform `incallui` `CATEGORY_CALL`
 * notification provides the second signal:
 * - **Monotonic clock (`osra-security#50`)**: all deadlines and comparisons use `SystemClock.elapsedRealtime()`
 *   (injectable for JVM tests) measured when the agent observes the event — never `Notification.when`,
 *   `StatusBarNotification.postTime`, or `System.currentTimeMillis()`, so wall-clock jumps cannot extend
 *   the exemption. If the scheduled timer fires early relative to the monotonic deadline, it re-arms for
 *   the remaining monotonic duration while preserving the original fixed deadline.
 * - **Fixed per-call deadline (`osra-security#49`)**: duplicate or periodic updates of the same active
 *   call keep the initial `ringUntilMs` and never push out the 45-second ceiling.
 * - **Owner-key removal matching (`osra-security#43`, `osra-security#49`)**: once `ownerKey` is known,
 *   `onNotificationRemoved` closes the window only when `key == ownerKey` (ignoring outdated removals of
 *   an earlier call key); before a key is attached (accessibility-only path), a `CATEGORY_CALL` removal
 *   from `ownerPkg` closes it.
 * - **Unified close & expiry path (`osra-security#49`, `osra-security#50`)**: reaching `ringUntilMs`
 *   clears the window and invokes the same `onWindowClosed` collapse callback as explicit notification removal.
 * - **Blocked-ring override & fail-closed `MODE_RINGTONE` (`osra-security#33`, `osra-security#48`)**:
 *   `MODE_RINGTONE` exempts the shade only when a trusted platform call owns the ring and `blockedRingActive` is false.
 */
object IncomingRingWindow {
    const val WINDOW_MS = 45_000L

    interface Scheduler {
        fun schedule(delayMs: Long, action: () -> Unit)
        fun cancel()
    }

    data class State(
        val ringUntilMs: Long = 0L,
        val ownerPkg: String? = null,
        val ownerKey: String? = null,
    )

    private val lock = Any()
    @Volatile private var sharedState = State()
    @Volatile private var onWindowClosed: (() -> Unit)? = null
    @Volatile private var scheduler: Scheduler? = null
    @Volatile private var elapsedClock: () -> Long = { SystemClock.elapsedRealtime() }

    private fun nowElapsed(): Long = elapsedClock()

    internal fun setClockForTest(clock: () -> Long) {
        synchronized(lock) {
            elapsedClock = clock
        }
    }

    fun setOnWindowClosed(listener: (() -> Unit)?) {
        onWindowClosed = listener
    }

    fun bindCallbacks(onClosed: (() -> Unit)?, expiryScheduler: Scheduler? = null) {
        synchronized(lock) {
            onWindowClosed = onClosed
            scheduler = expiryScheduler
        }
    }

    fun unbindCallbacks() {
        val oldScheduler = synchronized(lock) {
            val current = scheduler
            onWindowClosed = null
            scheduler = null
            current
        }
        oldScheduler?.cancel()
    }

    fun resetForTest() {
        val oldScheduler = synchronized(lock) {
            val current = scheduler
            sharedState = State()
            onWindowClosed = null
            scheduler = null
            elapsedClock = { SystemClock.elapsedRealtime() }
            current
        }
        oldScheduler?.cancel()
    }

    internal fun currentStateForTest(): State = synchronized(lock) { sharedState }

    /**
     * Scheduled timer callback (`osra-security#50`): if the handler wakes before the monotonic deadline
     * (e.g. `uptimeMillis` vs `elapsedRealtime` divergence or timer coalescing), re-arm for the remaining
     * duration against the same fixed deadline; otherwise expire and invoke `onWindowClosed`.
     */
    fun onTimerFired(nowMs: Long = nowElapsed()): Boolean {
        var expired = false
        var remainingMs: Long? = null
        synchronized(lock) {
            val before = sharedState
            when {
                before.ringUntilMs <= 0L -> Unit
                nowMs >= before.ringUntilMs -> {
                    sharedState = State()
                    expired = true
                }
                else -> {
                    remainingMs = before.ringUntilMs - nowMs
                }
            }
        }
        if (expired) {
            scheduler?.cancel()
            onWindowClosed?.invoke()
        } else if (remainingMs != null) {
            scheduler?.schedule(remainingMs!!) { onTimerFired() }
        }
        return expired
    }

    fun expireIfDue(nowMs: Long = nowElapsed()): Boolean {
        val expired = synchronized(lock) {
            val before = sharedState
            if (before.ringUntilMs in 1..nowMs) {
                sharedState = State()
                true
            } else {
                false
            }
        }
        if (expired) {
            scheduler?.cancel()
            onWindowClosed?.invoke()
        }
        return expired
    }

    fun clearSharedWindow(nowMs: Long = nowElapsed()) {
        val hadWindow = synchronized(lock) {
            val activeOrDue = sharedState.ringUntilMs > 0L
            sharedState = State()
            activeOrDue
        }
        if (hadWindow) {
            scheduler?.cancel()
            onWindowClosed?.invoke()
        }
    }

    fun recordPostedNotice(
        pkg: String,
        key: String?,
        isCall: Boolean,
        isMissedCall: Boolean = false,
        hasDecline: Boolean,
        hasHangUp: Boolean,
        mode: CallAudioMode,
        nowMs: Long,
        fromTrustedSource: Boolean,
    ) {
        var notifyClosed = false
        var cancelTimer = false
        var scheduleDelayMs: Long? = null
        synchronized(lock) {
            var before = sharedState
            var expiredNow = false
            if (before.ringUntilMs in 1..nowMs) {
                sharedState = State()
                before = State()
                expiredNow = true
                cancelTimer = true
            }
            val wasOpen = before.ringUntilMs > nowMs
            if (!fromTrustedSource) {
                notifyClosed = expiredNow
                return@synchronized
            }
            if (isMissedCall) {
                sharedState = State()
                cancelTimer = cancelTimer || wasOpen
                notifyClosed = expiredNow || wasOpen
                return@synchronized
            }
            if (!isCall) {
                notifyClosed = expiredNow
                return@synchronized
            }
            if (hasHangUp || mode == CallAudioMode.IN_CALL || mode == CallAudioMode.IN_COMMUNICATION) {
                sharedState = State()
                cancelTimer = cancelTimer || wasOpen
                notifyClosed = expiredNow || wasOpen
                return@synchronized
            }
            if (hasDecline) {
                if (mode == CallAudioMode.NORMAL) {
                    if (wasOpen) {
                        val distinctNewKey = before.ownerKey != null && key != null && key != before.ownerKey
                        if (distinctNewKey) {
                            sharedState = State(
                                ringUntilMs = nowMs + WINDOW_MS,
                                ownerPkg = pkg,
                                ownerKey = key,
                            )
                            scheduleDelayMs = WINDOW_MS
                        } else {
                            // Duplicate or cross-channel update of the active call: keep the fixed deadline.
                            sharedState = before.copy(
                                ownerKey = before.ownerKey ?: key,
                            )
                        }
                    } else {
                        sharedState = State(
                            ringUntilMs = nowMs + WINDOW_MS,
                            ownerPkg = pkg,
                            ownerKey = key,
                        )
                        scheduleDelayMs = WINDOW_MS
                        cancelTimer = false
                        expiredNow = false
                    }
                } else if (wasOpen && key != null && before.ownerKey == null && before.ownerPkg == pkg) {
                    sharedState = before.copy(ownerKey = key)
                }
            }
            notifyClosed = expiredNow
        }
        if (scheduleDelayMs != null) {
            scheduler?.schedule(scheduleDelayMs!!) { onTimerFired() }
        } else if (cancelTimer) {
            scheduler?.cancel()
        }
        if (notifyClosed) onWindowClosed?.invoke()
    }

    fun recordRemovedNotice(
        pkg: String,
        key: String?,
        isCall: Boolean,
        nowMs: Long = nowElapsed(),
    ) {
        var notifyClosed = false
        var cancelTimer = false
        synchronized(lock) {
            val before = sharedState
            if (before.ringUntilMs == 0L) return@synchronized
            if (nowMs >= before.ringUntilMs) {
                sharedState = State()
                cancelTimer = true
                notifyClosed = true
                return@synchronized
            }
            val matches = if (before.ownerKey != null) {
                key != null && key == before.ownerKey
            } else {
                before.ownerPkg != null && pkg == before.ownerPkg && isCall
            }
            if (!matches) return@synchronized
            sharedState = State()
            cancelTimer = true
            notifyClosed = true
        }
        if (cancelTimer) scheduler?.cancel()
        if (notifyClosed) onWindowClosed?.invoke()
    }

    fun isSharedRinging(
        mode: CallAudioMode,
        nowMs: Long,
        blockedRingActive: Boolean = false,
        trustedRingOwner: Boolean = false,
    ): Boolean {
        expireIfDue(nowMs)
        val until = synchronized(lock) { sharedState.ringUntilMs }
        return isRinging(
            mode = mode,
            nowMs = nowMs,
            ringUntilMs = until,
            blockedRingActive = blockedRingActive,
            trustedRingOwner = trustedRingOwner,
        )
    }

    fun fromTrustedSource(pkg: String, defaultDialer: String?, platformInCallUi: Set<String>): Boolean =
        pkg == defaultDialer || pkg in platformInCallUi

    fun isRinging(
        mode: CallAudioMode,
        nowMs: Long,
        ringUntilMs: Long,
        blockedRingActive: Boolean = false,
        trustedRingOwner: Boolean = false,
    ): Boolean {
        if (blockedRingActive) return false
        return when {
            // osra-security#48 R1: fail closed on MODE_RINGTONE — exempt only when a trusted platform call owns the ring.
            mode == CallAudioMode.RINGTONE -> trustedRingOwner
            mode == CallAudioMode.NORMAL -> nowMs < ringUntilMs
            else -> false
        }
    }
}
