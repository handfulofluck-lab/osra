package com.familyshield.agent.enforcement

/**
 * #828 / #851 / osra-security#33 / osra-security#43: incoming cellular call exemption for the lock shade guard.
 *
 * Under a silent ringer or DND, `AudioManager.mode` stays `MODE_NORMAL` for the whole ring, so a
 * bounded 45-second upper-bound window from a trusted dialer / platform `incallui` `CATEGORY_CALL`
 * notification provides the second signal. Under `osra-security#43` (Ahmed B1), removing that call
 * notification (`NotificationListenerService.onNotificationRemoved`) or posting a `CATEGORY_MISSED_CALL`
 * notice closes the window immediately instead of waiting out the 45-second bound, and notifies the
 * accessibility service so an already-pulled shade collapses at once. Under `osra-security#33`,
 * `blockedRingActive` overrides `MODE_RINGTONE` whenever a blocked or locked non-essential app owns
 * the ring, preventing non-essential VoIP rings from propping the shade open during a lock or pause.
 */
object IncomingRingWindow {
    const val WINDOW_MS = 45_000L

    data class State(
        val ringUntilMs: Long = 0L,
        val ownerPkg: String? = null,
        val ownerKey: String? = null,
    )

    private val lock = Any()
    @Volatile private var sharedState = State()
    @Volatile private var onWindowClosed: (() -> Unit)? = null

    fun setOnWindowClosed(listener: (() -> Unit)?) {
        onWindowClosed = listener
    }

    fun resetForTest() {
        synchronized(lock) {
            sharedState = State()
            onWindowClosed = null
        }
    }

    fun clearSharedWindow(nowMs: Long = System.currentTimeMillis()) {
        val notify = synchronized(lock) {
            val wasOpen = nowMs < sharedState.ringUntilMs
            sharedState = State()
            wasOpen
        }
        if (notify) onWindowClosed?.invoke()
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
        val notify = synchronized(lock) {
            val before = sharedState
            val wasOpen = nowMs < before.ringUntilMs
            if (!fromTrustedSource) return@synchronized false
            if (isMissedCall) {
                sharedState = State()
                return@synchronized wasOpen
            }
            if (!isCall) return@synchronized false
            if (hasHangUp) {
                sharedState = State()
                return@synchronized wasOpen
            }
            if (hasDecline) {
                if (mode == CallAudioMode.NORMAL) {
                    val effectiveKey = key ?: if (before.ownerPkg == pkg) before.ownerKey else null
                    sharedState = State(
                        ringUntilMs = nowMs + WINDOW_MS,
                        ownerPkg = pkg,
                        ownerKey = effectiveKey,
                    )
                } else if (key != null && before.ownerPkg == pkg && nowMs < before.ringUntilMs) {
                    sharedState = before.copy(ownerKey = key)
                }
            }
            false
        }
        if (notify) onWindowClosed?.invoke()
    }

    fun recordRemovedNotice(
        pkg: String,
        key: String?,
        isCall: Boolean,
        nowMs: Long = System.currentTimeMillis(),
    ) {
        val notify = synchronized(lock) {
            val before = sharedState
            if (before.ringUntilMs == 0L) return@synchronized false
            val keyMatches = before.ownerKey != null && key != null && key == before.ownerKey
            val pkgMatches = before.ownerPkg != null && pkg == before.ownerPkg && (isCall || before.ownerKey == null)
            if (!keyMatches && !pkgMatches) return@synchronized false
            val wasOpen = nowMs < before.ringUntilMs
            sharedState = State()
            wasOpen
        }
        if (notify) onWindowClosed?.invoke()
    }

    fun isSharedRinging(
        mode: CallAudioMode,
        nowMs: Long,
        blockedRingActive: Boolean = false,
    ): Boolean = isRinging(mode, nowMs, sharedState.ringUntilMs, blockedRingActive = blockedRingActive)

    fun next(
        isCall: Boolean,
        hasDecline: Boolean,
        hasHangUp: Boolean,
        mode: CallAudioMode,
        nowMs: Long,
        fromDefaultDialer: Boolean,
    ): Long? {
        if (!isCall) return null
        if (!fromDefaultDialer) return null
        if (hasHangUp) return 0L
        if (hasDecline && mode == CallAudioMode.NORMAL) return nowMs + WINDOW_MS
        return null
    }

    fun fromTrustedSource(pkg: String, defaultDialer: String?, platformInCallUi: Set<String>): Boolean =
        pkg == defaultDialer || pkg in platformInCallUi

    fun isRinging(
        mode: CallAudioMode,
        nowMs: Long,
        ringUntilMs: Long,
        blockedRingActive: Boolean = false,
    ): Boolean {
        if (blockedRingActive) return false
        return when {
            mode == CallAudioMode.RINGTONE -> true
            mode == CallAudioMode.NORMAL -> nowMs < ringUntilMs
            else -> false
        }
    }
}
