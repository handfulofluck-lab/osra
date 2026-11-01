package com.familyshield.agent.social

/**
 * Roadmap 4.5 — a WhatsApp call as a **call row**, never as content. The decisions, as a pure function.
 *
 * WhatsApp tells the phone a small number of things about a call: a ringing heads-up, an updated
 * notification while it is in progress, a "missed call" notice when it was not answered, and the removal of
 * the heads-up when it ends. From those we can honestly report **who, when, and roughly how long** — and
 * nothing else:
 *
 * - the caller name is the notification's title, because WhatsApp gives no number;
 * - **the direction is `unknown` for a live call.** WhatsApp keeps an ongoing-call notification
 *   (category `call`, a Hang up action) for the whole of *any* call, outgoing included, so a call the child
 *   placed looks exactly like one they received. Saying `incoming` would state something false about the
 *   child; losing the arrow costs a detail, inventing it costs the parent's trust (Claude, #523 review);
 * - a duration is the difference between the heads-up and its removal, so it is **approximate**, and
 *   [Call.durationApprox] says so rather than letting the parent read it as a measured time;
 * - an **unanswered** call produces no `ended` row at all — the missed notice owns that row, so a ring that
 *   was ignored is one row with no duration, not two rows, one of which claims 25 seconds of call;
 * - a missed call has **no** duration: null, not zero, because "0 s" reads as a call that connected;
 * - the notification's **body never enters this object**: [Snapshot] has no field for it and [Call] has
 *   none either, so neither the way in nor the way out can carry a message.
 *
 * **A call is told from a message by the notification's category**, not by having a title: every WhatsApp
 * chat message also arrives with the sender's name in the title. `started`/`ended` require
 * `Notification.CATEGORY_CALL` and `missed` requires `CATEGORY_MISSED_CALL`, which is API 30+ — on an older
 * phone no missed row is produced rather than a guessed one.
 *
 * The adapter (`NotificationCaptureService`, Full flavour only) owns the platform mapping, the pause gate and
 * the "first `startMs` wins per key" rule; this object decides what a call looks like once it has the facts.
 */
object WhatsAppCallPolicy {

    /** `Notification.CATEGORY_CALL`. */
    const val CATEGORY_CALL = "call"

    /** `Notification.CATEGORY_MISSED_CALL` (API 30). */
    const val CATEGORY_MISSED_CALL = "missed_call"

    /**
     * The fields of a posted/removed call notification this needs, as primitives — no Android types.
     *
     * There is deliberately no `text`: the adapter cannot hand us a body it does not pass, so fault 4 of the
     * review is structural on the way in as well as on the way out.
     */
    data class Snapshot(
        val packageId: String,
        /** `StatusBarNotification.key`: stable across the updates of one call. */
        val key: String,
        /** `Notification.category`: what tells a call from a message. */
        val category: String? = null,
        /** WhatsApp puts the caller's display name here; it is the only identity we are given. */
        val title: String? = null,
        val postedAtMs: Long = 0L,
    )

    /** One call row: who, when, how long — and nothing that could carry content, and no guessed direction. */
    data class Call(
        val contact: String,
        /** `unknown` for a live call, `missed` for one that was not answered. Never guessed. */
        val direction: String,
        /** Seconds, or null when the call never connected. */
        val durationSec: Long?,
        /** True whenever [durationSec] is present: it is measured from notifications, not timed. */
        val durationApprox: Boolean,
        val startMs: Long,
        /** The notification key, for [identity]. */
        val key: String,
    )

    // The values `direction` may take, named so a typo is a compile error rather than a silent new state.
    const val DIRECTION_UNKNOWN = "unknown"
    const val DIRECTION_MISSED = "missed"

    /**
     * The identity of one call: the notification key **plus** the start time.
     *
     * The key alone is not enough — WhatsApp reuses it — and the start alone is not enough either: two
     * missed calls from the same person in the same second are two calls. Together they make the updates of
     * one call one row.
     */
    fun identity(call: Call): String = "${call.key}|${call.startMs}"

    /** The caller name, or null when WhatsApp gave us nothing to name. */
    private fun contactOf(snapshot: Snapshot): String? =
        snapshot.title?.trim()?.takeIf { it.isNotEmpty() }

    /** WhatsApp, a name on the screen, and the given category — everything the row below needs. */
    private fun isCallLike(snapshot: Snapshot, category: String): Boolean =
        MonitoredApps.appKeyFor(snapshot.packageId) == "whatsapp" &&
            snapshot.category == category &&
            contactOf(snapshot) != null

    /**
     * A call that is ringing or in progress: `unknown` direction, no duration yet.
     *
     * Returns null for a missed notice, for a message (category `msg`), for another app, and for a
     * notification with no name — an unnamed row ("Incoming call") tells the parent nothing they can act on.
     */
    fun started(snapshot: Snapshot): Call? {
        if (!isCallLike(snapshot, CATEGORY_CALL)) return null
        return Call(
            contact = contactOf(snapshot)!!,
            direction = DIRECTION_UNKNOWN,
            durationSec = null,
            durationApprox = false,
            startMs = snapshot.postedAtMs,
            key = snapshot.key,
        )
    }

    /**
     * The same call once its heads-up is gone: the row that carries the duration.
     *
     * @param startedAtMs when [started] produced the row, from the call it returned as [Call.startMs]
     * @param answered true when the adapter saw the notification change from ringing to in progress. An
     *   unanswered call returns null: it rang and ended, and the `missed_call` notice is the row for it.
     */
    fun ended(snapshot: Snapshot, startedAtMs: Long, answered: Boolean): Call? {
        if (!answered) return null
        if (!isCallLike(snapshot, CATEGORY_CALL)) return null
        // A clock that went backwards must not produce a negative duration or a wild one: a removal dated
        // before the start is "just started", and anything beyond a day is not a call we watched.
        val elapsedMs = (snapshot.postedAtMs - startedAtMs).coerceIn(0L, MAX_CALL_MS)
        return Call(
            contact = contactOf(snapshot)!!,
            direction = DIRECTION_UNKNOWN,
            durationSec = elapsedMs / 1_000L,
            durationApprox = true,
            startMs = startedAtMs,
            key = snapshot.key,
        )
    }

    /**
     * A call that was never answered: `missed`, and **no** duration — null, not zero.
     *
     * Below API 30 there is no `CATEGORY_MISSED_CALL`, so this returns null there rather than guessing from
     * wording; the parent loses a missed row, not the truth.
     */
    fun missed(snapshot: Snapshot): Call? {
        if (!isCallLike(snapshot, CATEGORY_MISSED_CALL)) return null
        return Call(
            contact = contactOf(snapshot)!!,
            direction = DIRECTION_MISSED,
            durationSec = null,
            durationApprox = false,
            startMs = snapshot.postedAtMs,
            key = snapshot.key,
        )
    }

    /** A call longer than this is not one we watched end; 24 hours is generous and stops a wild number. */
    private const val MAX_CALL_MS = 24L * 60 * 60 * 1000
}
