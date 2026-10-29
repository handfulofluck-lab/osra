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
 * usable afterwards." Claude chose the mechanisms from the #446 measurements; the #449 review fixed four gaps.
 *
 * - **C1, a blocked app rings.** Unlocked: its `CallStyle` decline intent is sent once per ring (the Flip4's
 *   Meet ring is `ongoing=true`, so "incoming" means *not yet in a call*, never `!ongoing`), and a full-screen
 *   cover sits over the ringing UI. The cover lasts [shortCoverMs] until RINGTONE is seen (the decline often
 *   ends the ring before the app ever sets it) and at most [coverMaxMs] after; it comes down when the mode
 *   leaves RINGTONE. Locked, the event has no parcel: the cover goes up at RINGTONE only when a **blocked**
 *   package posted within [freshMs] before it. Any non-blocked post during the ring drops it at once, so an
 *   allowed or a real phone call is never covered.
 * - **C2, a blocked call connects anyway.** The call belongs to the package that rang (RINGTONE → call), or,
 *   for an outgoing call, to a call notification posted within [freshMs] of the mode change. Never to an older
 *   or unstamped poster. The cached hang-up is sent; with none cached (locked), the first parcel that carries
 *   one sends it. A call still up after [reportAfterMs] is reported through the shared [floor].
 * - **C3, the block arrives mid-call.** A call whose package was **not** blocked when it connected is left
 *   alone until the mode returns to NORMAL; the window block still applies.
 *
 * Pure, with the clock as a parameter: every row is a JVM test.
 */
class CallBlockPolicy(
    private val floor: BypassAlertFloor = BypassAlertFloor(),
    private val reportAfterMs: Long = DEFAULT_REPORT_AFTER_MS,
    private val coverMaxMs: Long = DEFAULT_COVER_MAX_MS,
    private val shortCoverMs: Long = DEFAULT_SHORT_COVER_MS,
    private val freshMs: Long = DEFAULT_FRESH_MS,
) {
    private data class Posted(val pkg: String, val blocked: Boolean, val atMs: Long)

    private var mode = CallAudioMode.NORMAL
    private var lastPost: Posted? = null
    private var lastCallPost: Posted? = null
    private var ringPkg: String? = null
    private var nonBlockedPostedDuringRing = false
    private var coverUntilMs: Long? = null
    private var ringSeenWithCover = false
    private val declined = HashSet<String>()
    private val hangUpCached = HashSet<String>()
    private var callPkg: String? = null
    private var callStartMs = 0L
    private var callExempt = false
    private var hangUpSent = false
    private var callReported = false

    val coverShown: Boolean get() = coverUntilMs != null

    /** One accessibility notification event (the agent's own package is filtered out by the caller). */
    fun onNotification(
        notice: CallNotice,
        isBlocked: (String) -> Boolean,
        isEssential: (String) -> Boolean,
        nowMs: Long,
    ): List<CallAction> {
        val out = ArrayList<CallAction>()
        val pkg = notice.pkg
        val blocked = !isEssential(pkg) && isBlocked(pkg)
        if (!blocked) {
            // An allowed app, the dialer or an emergency app posted: whatever is ringing may be theirs.
            if (mode == CallAudioMode.RINGTONE) nonBlockedPostedDuringRing = true
            if (coverShown) out += removeCover()
        }
        val posted = Posted(pkg, blocked, nowMs)
        lastPost = posted
        val parcel = notice.parcel ?: return out
        if (!parcel.isCall) return out
        lastCallPost = posted
        if (!blocked) return out
        if (parcel.hasHangUp) hangUpCached += pkg
        // C3: the one guard for a call that connected before its block (the #449 fault F3 removes it).
        if (callExempt && callPkg == pkg) return out
        // Outgoing call: the call mode came first and its notification follows within freshMs.
        if (inCall() && callPkg == null && nowMs - callStartMs in 0..freshMs) adopt(pkg, isBlocked)
        if (parcel.hasDecline && !inCall() && declined.add("$pkg|${parcel.postedAt}")) {
            out += CallAction.Decline(pkg)
            if (!nonBlockedPostedDuringRing && !coverShown) out += showCover(nowMs)
        }
        if (inCall() && parcel.hasHangUp && callPkg == pkg && !hangUpSent) {
            hangUpSent = true
            out += CallAction.HangUp(pkg)
        }
        return out
    }

    /** The audio mode, read from the mode listener (and on events below API 31). Repeats only tick. */
    fun onAudioMode(next: CallAudioMode, isBlocked: (String) -> Boolean, nowMs: Long): List<CallAction> {
        val previous = mode
        if (next == previous) return tick(nowMs)
        val out = ArrayList<CallAction>()
        mode = next
        if (previous == CallAudioMode.RINGTONE && coverShown) out += removeCover()
        when (next) {
            CallAudioMode.RINGTONE -> {
                nonBlockedPostedDuringRing = false
                val ringer = fresh(lastCallPost, nowMs) ?: fresh(lastPost, nowMs)
                ringPkg = ringer?.pkg
                if (coverShown) {
                    ringSeenWithCover = true
                    coverUntilMs = nowMs + coverMaxMs
                } else if (ringer != null && ringer.blocked) {
                    ringSeenWithCover = true
                    out += showCover(nowMs)
                }
            }
            CallAudioMode.IN_COMMUNICATION, CallAudioMode.IN_CALL -> if (callPkg == null) {
                callStartMs = nowMs
                hangUpSent = false
                callReported = false
                val owner = if (previous == CallAudioMode.RINGTONE) ringPkg else fresh(lastCallPost, nowMs)?.pkg
                if (owner != null) adopt(owner, isBlocked)
                val call = callPkg
                if (call != null && !callExempt && call in hangUpCached) {
                    hangUpSent = true
                    out += CallAction.HangUp(call)
                }
            }
            CallAudioMode.NORMAL -> endCall()
            CallAudioMode.OTHER -> Unit
        }
        return out + tick(nowMs)
    }

    /** Called on every mode reading and by the service's timer: the cover's limit and the C2 report. */
    fun tick(nowMs: Long): List<CallAction> {
        val out = ArrayList<CallAction>()
        val until = coverUntilMs
        if (until != null && nowMs >= until) out += removeCover()
        val call = callPkg
        if (call != null && inCall() && !callExempt && !callReported && nowMs - callStartMs >= reportAfterMs) {
            callReported = true
            if (floor.tryReport(call, nowMs)) out += CallAction.ReportCall(call, callStartMs)
        }
        return out
    }

    private fun adopt(pkg: String, isBlocked: (String) -> Boolean) {
        callPkg = pkg
        // C3: a call that connected before its package was blocked is left alone until NORMAL.
        callExempt = !isBlocked(pkg)
    }

    private fun fresh(posted: Posted?, nowMs: Long): Posted? =
        posted?.takeIf { nowMs - it.atMs in 0..freshMs }

    private fun inCall() = mode == CallAudioMode.IN_COMMUNICATION || mode == CallAudioMode.IN_CALL

    private fun showCover(nowMs: Long): CallAction {
        coverUntilMs = nowMs + if (ringSeenWithCover) coverMaxMs else shortCoverMs
        return CallAction.ShowRingCover
    }

    private fun removeCover(): CallAction {
        coverUntilMs = null
        ringSeenWithCover = false
        return CallAction.RemoveRingCover
    }

    private fun endCall() {
        callPkg = null
        callExempt = false
        hangUpSent = false
        callReported = false
        ringPkg = null
        hangUpCached.clear()
        declined.clear()
        nonBlockedPostedDuringRing = false
    }

    companion object {
        /** "If the call still lasts more than 15 s" (Claude, #444). */
        const val DEFAULT_REPORT_AFTER_MS: Long = 15_000L

        /** Once RINGTONE was seen, the cover still never outlives a minute. */
        const val DEFAULT_COVER_MAX_MS: Long = 60_000L

        /** Before RINGTONE is seen (the decline may end the ring first): about five seconds (#449 review). */
        const val DEFAULT_SHORT_COVER_MS: Long = 5_000L

        /** A poster counts for a ring or a call only within this long before it (#449 review). */
        const val DEFAULT_FRESH_MS: Long = 5_000L
    }
}
