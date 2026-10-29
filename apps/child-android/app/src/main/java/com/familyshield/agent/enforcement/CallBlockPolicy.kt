package com.familyshield.agent.enforcement

/** The audio modes the call rules care about (`AudioManager.MODE_*`). */
enum class CallAudioMode { NORMAL, RINGTONE, IN_CALL, IN_COMMUNICATION, OTHER }

/**
 * What the agent can read from one accessibility notification event about a call.
 *
 * On the Flip4 (#444 M1–M4) an unlocked ring arrives as a `CATEGORY_CALL` notification with a `CallStyle`
 * template carrying `android.declineIntent`, `answerIntent` and `hangUpIntent`; the actions' semantic
 * action is NONE, so the extras are the only text-free handle. On the lock screen the same event has no
 * parcel at all ([CallNotice.parcel] null): only the package is known.
 */
data class CallParcel(
    val isCall: Boolean,
    val hasDecline: Boolean,
    val hasHangUp: Boolean,
    val ongoing: Boolean,
    /** `Notification.when`: with the package, one ring's identity, so its decline is sent once. */
    val postedAt: Long,
)

data class CallNotice(val pkg: String, val parcel: CallParcel?)

/** One thing the service must do. The pending intents themselves stay in the service's cache. */
sealed interface CallAction {
    /** C1: send the cached `CallStyle` decline intent of [pkg]. */
    data class Decline(val pkg: String) : CallAction

    /** C2: send the cached `CallStyle` hang-up intent of [pkg]. */
    data class HangUp(val pkg: String) : CallAction

    /** C1 backstop: the full-screen accessibility cover over the ringing UI. */
    data object ShowRingCover : CallAction

    data object RemoveRingCover : CallAction

    /** C2: the blocked call kept going; one `tamper` `block_bypass` alert with `layout: call`. */
    data class ReportCall(val pkg: String, val callStartMs: Long) : CallAction
}

/**
 * Issue #444, Karim's rule (29 Oct): "when i have google meet blocked it should not be able to make or receive
 * calls … applying the block in the middle of a call should not terminate the call but the app should not be
 * usable afterwards." Claude chose the mechanisms from the #446 measurements:
 *
 * - **C1, a blocked app rings.** Unlocked: its `CallStyle` decline intent is sent once per ring, and a
 *   full-screen cover sits over the ringing UI until the audio mode leaves RINGTONE (the block screen alone
 *   was answered through in 1.1 s on the Flip4). Locked, the event has no parcel: when the **last**
 *   notification before RINGTONE came from a blocked package, the cover goes up; it is dropped at once if an
 *   essential package (dialer, emergency) posts during the ring, so a real phone call is never covered.
 * - **C2, a blocked call connects anyway.** When the mode becomes IN_COMMUNICATION for a blocked package
 *   with a cached hang-up intent, the hang-up is sent; with none cached (locked), the first parcel that
 *   carries one sends it. A call still up after [reportAfterMs] is reported once per [reportFloorMs].
 * - **C3, the block arrives mid-call.** A call whose package was **not** blocked when it connected is left
 *   alone until the mode returns to NORMAL; the window block still applies.
 *
 * Essential packages are never blocked (`RuleRepository.decide` answers ALLOW for them), so the caller's
 * `isBlocked` already leaves the dialer alone; the cover drop above is the one extra rule for them.
 * Pure, with the clock as a parameter: every row is a JVM test.
 */
class CallBlockPolicy(
    private val reportAfterMs: Long = DEFAULT_REPORT_AFTER_MS,
    private val reportFloorMs: Long = BlockRaisePolicy.DEFAULT_BYPASS_FLOOR_MS,
    private val coverMaxMs: Long = DEFAULT_COVER_MAX_MS,
) {
    private var mode = CallAudioMode.NORMAL
    private var lastPoster: String? = null
    private var lastPosterBlocked = false
    /** The last package whose parcel said `CATEGORY_CALL`, blocked or not: the call's owner when it connects. */
    private var lastCallPoster: String? = null
    private var essentialPostedDuringRing = false
    private var coverUntilMs: Long? = null
    private val declined = HashSet<String>()
    private val hangUpCached = HashSet<String>()
    private var callPkg: String? = null
    private var callStartMs = 0L
    private var callExempt = false
    private var hangUpSent = false
    private var callReported = false
    private val lastReportMs = HashMap<String, Long>()

    val coverShown: Boolean get() = coverUntilMs != null

    /** One accessibility notification event. [isEssential] is the facts-aware essential check. */
    fun onNotification(
        notice: CallNotice,
        isBlocked: (String) -> Boolean,
        isEssential: (String) -> Boolean,
        nowMs: Long,
    ): List<CallAction> {
        val out = ArrayList<CallAction>()
        val pkg = notice.pkg
        val essential = isEssential(pkg)
        val blocked = !essential && isBlocked(pkg)
        lastPoster = pkg
        lastPosterBlocked = blocked
        if (essential && (mode == CallAudioMode.RINGTONE || coverShown)) {
            // A real phone call (or an emergency) is ringing too: never cover it.
            essentialPostedDuringRing = true
            if (coverShown) out += removeCover()
        }
        val parcel = notice.parcel ?: return out
        if (parcel.isCall) lastCallPoster = pkg
        if (!parcel.isCall || !blocked) return out
        if (parcel.hasHangUp) hangUpCached += pkg
        val exempt = callExempt && callPkg == pkg
        if (exempt) return out
        if (parcel.hasDecline && !parcel.ongoing && declined.add("$pkg|${parcel.postedAt}")) {
            out += CallAction.Decline(pkg)
            if (!essentialPostedDuringRing && !coverShown) out += showCover(nowMs)
        }
        if (inCall() && parcel.hasHangUp && callPkg == pkg && !hangUpSent) {
            hangUpSent = true
            out += CallAction.HangUp(pkg)
        }
        return out
    }

    /** The audio mode, read on every event and from the mode listener. Repeats are ignored. */
    fun onAudioMode(next: CallAudioMode, isBlocked: (String) -> Boolean, nowMs: Long): List<CallAction> {
        val out = ArrayList<CallAction>()
        val previous = mode
        if (next == previous) return tick(nowMs)
        mode = next
        if (previous == CallAudioMode.RINGTONE && coverShown) out += removeCover()
        when (next) {
            CallAudioMode.RINGTONE -> {
                essentialPostedDuringRing = false
                // Locked: no parcel, so the last poster before the ring is the only name we have.
                if (lastPosterBlocked && !coverShown) out += showCover(nowMs)
            }
            CallAudioMode.IN_COMMUNICATION, CallAudioMode.IN_CALL -> {
                val pkg = lastCallPoster ?: lastPoster
                if (callPkg == null && pkg != null) {
                    callPkg = pkg
                    callStartMs = nowMs
                    // C3: a call that connected before its package was blocked is left alone until NORMAL.
                    callExempt = !isBlocked(pkg)
                    hangUpSent = false
                    callReported = false
                }
                val call = callPkg
                if (call != null && !callExempt && call in hangUpCached && !hangUpSent) {
                    hangUpSent = true
                    out += CallAction.HangUp(call)
                }
            }
            CallAudioMode.NORMAL -> endCall()
            CallAudioMode.OTHER -> Unit
        }
        return out
    }

    /** Called on every event and by the service's timer: the cover's time limit and the C2 report. */
    fun tick(nowMs: Long): List<CallAction> {
        val out = ArrayList<CallAction>()
        val until = coverUntilMs
        if (until != null && nowMs >= until) out += removeCover()
        val call = callPkg
        if (call != null && inCall() && !callExempt && !callReported && nowMs - callStartMs >= reportAfterMs) {
            callReported = true
            val last = lastReportMs[call]
            if (last == null || nowMs - last !in 0 until reportFloorMs) {
                lastReportMs[call] = nowMs
                out += CallAction.ReportCall(call, callStartMs)
            }
        }
        return out
    }

    private fun inCall() = mode == CallAudioMode.IN_COMMUNICATION || mode == CallAudioMode.IN_CALL

    private fun showCover(nowMs: Long): CallAction {
        coverUntilMs = nowMs + coverMaxMs
        return CallAction.ShowRingCover
    }

    private fun removeCover(): CallAction {
        coverUntilMs = null
        return CallAction.RemoveRingCover
    }

    private fun endCall() {
        callPkg = null
        callExempt = false
        hangUpSent = false
        callReported = false
        hangUpCached.clear()
        lastCallPoster = null
        essentialPostedDuringRing = false
    }

    companion object {
        /** "If the call still lasts more than 15 s" (Claude, #444). */
        const val DEFAULT_REPORT_AFTER_MS: Long = 15_000L

        /** A ring with no RINGTONE mode (silent, vibrate) must not leave the cover up for good. */
        const val DEFAULT_COVER_MAX_MS: Long = 60_000L
    }
}
