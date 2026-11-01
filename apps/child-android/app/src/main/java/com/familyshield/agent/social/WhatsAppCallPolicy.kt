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
 * **"Answered" is measured from the notification changing, not guessed.** On the Flip4 capture (Claude,
 * #50, 1 Nov 2026) a ring is posted on `voip_notification_4` at importance 4, and the same key changes to
 * `silent_notifications_3` at importance 2 once the call is answered. Both signals are used, and the channel is
 * compared on its **prefix** because the numeric suffix moves between calls. `FLAG_FOREGROUND_SERVICE` is
 * deliberately *not* a signal: the outgoing call carried it from its very first row.
 *
 * **A call that ends without being answered may leave no notice at all.** The capture's outgoing call was
 * posted and then removed 25 s later with no change and no `missed_call`, so [ended] returns null and
 * [missed] never fires. [unanswered] is the row for that case: `unknown` direction and a **null** duration,
 * because we cannot tell whether it connected and a 25 s "duration" on a call nobody answered is a lie.
 *
 * The adapter (`NotificationCaptureService`, Full flavour only) owns the platform mapping, the pause gate and
 * the "first `startMs` wins per key" rule; this object decides what a call looks like once it has the facts,
 * and [WhatsAppCallTracker] decides the order those facts arrive in.
 */
object WhatsAppCallPolicy {

    /** `Notification.CATEGORY_CALL`. */
    const val CATEGORY_CALL = "call"

    /** `Notification.CATEGORY_MISSED_CALL` (API 30). */
    const val CATEGORY_MISSED_CALL = "missed_call"

    /** Channel prefix of a ringing call (`voip_notification`, `voip_notification_4`, …). */
    const val CHANNEL_VOIP_PREFIX = "voip_notification"

    /** Channel prefix of an in-progress call (`silent_notifications`, `silent_notifications_3`, …). */
    const val CHANNEL_SILENT_PREFIX = "silent_notifications"

    /**
     * How long to wait, after a `call` heads-up is removed unanswered, for the `missed_call` notice.
     *
     * The capture measured 1.2 s (removed 10:42:02.930, missed posted 10:42:04.133); 5 s is the margin, not
     * the measurement. A longer window holds a row back from the parent for no reason.
     */
    const val MISSED_PAIRING_WINDOW_MS = 5_000L

    /**
     * The `source` these rows carry on the wire — the parent app shows "WhatsApp" for it, and it is what tells
     * a row the notifications produced from a row the call log wrote (roadmap 4.5).
     */
    const val SOURCE = "whatsapp"

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
        /**
         * `StatusBarNotification.user.identifier` — the Android profile the notification belongs to.
         *
         * Kept because a missed notice is paired with the ring it belongs to, and the Dual Messenger clone runs
         * the same package in user 95 (Claude's rule 4: never filter to user 0, and never pair across profiles).
         */
        val userId: Int = 0,
        /** `Ranking.importance` as posted — 4 ringing, 2 in progress. Null when the platform gave none. */
        val importance: Int? = null,
        /** `Notification.channelId` — `voip_notification_4` ringing, `silent_notifications_3` in progress. */
        val channelId: String? = null,
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
     * @param startedAtMs when the call rang — the row is **dated** to it, so the timeline says "at 10:42", not
     *   "at 10:42:57". It is not where the length starts: a call that rings for 25 s and then talks for 10 s did
     *   not last 35 s, so the clock starts when it was answered.
     * @param answered true when the adapter saw the notification change from ringing to in progress. An
     *   unanswered call returns null: it rang and ended, and the `missed_call` notice is the row for it.
     * @param removedAtMs when the heads-up disappeared. **Not** `sbn.postTime`: a removal carries the time the
     *   notification was *posted*, so defaulting to it would report every call as lasting 0 s.
     * @param answeredAtMs when the change that answered it was seen — the start of the measured length. Defaults
     *   to the ring only for a caller that has no better fact, which is why the adapter always passes it.
     */
    fun ended(
        snapshot: Snapshot,
        startedAtMs: Long,
        answered: Boolean,
        removedAtMs: Long = snapshot.postedAtMs,
        answeredAtMs: Long = startedAtMs,
    ): Call? {
        if (!answered) return null
        if (!isCallLike(snapshot, CATEGORY_CALL)) return null
        // A clock that went backwards must not produce a negative duration or a wild one: a removal dated
        // before the start is "just started", and anything beyond a day is not a call we watched.
        val elapsedMs = (removedAtMs - answeredAtMs).coerceIn(0L, MAX_CALL_MS)
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
     * A call whose heads-up was removed without ever being answered, and with **no** `missed_call` notice.
     *
     * This is the outgoing call in Claude's capture: posted on `voip_notification_4` with FOREGROUND_SERVICE,
     * removed 25 s later, no change and no notice. The parent gets one row, `unknown` direction and a **null**
     * duration — not 0 (reads as a call that connected instantly) and not the elapsed time (we do not know
     * whether it connected at all).
     *
     * @param started the row [started] produced for this call; its contact, key and start are kept
     */
    fun unanswered(started: Call): Call = Call(
        contact = started.contact,
        direction = DIRECTION_UNKNOWN,
        durationSec = null,
        durationApprox = false,
        // The call is dated to when it rang, not to when we noticed it was gone.
        startMs = started.startMs,
        key = started.key,
    )

    /**
     * True when [current] is the *same* call now in progress: the heads-up became a silent ongoing row.
     *
     * Either signal is enough — importance falling (4 → 2 in the capture), or the channel moving from the
     * `voip_notification` prefix to the `silent_notifications` prefix. Both are compared on what the platform
     * reported; when it reports neither, this is false and the call gets the unknown row instead of a
     * duration it cannot back.
     */
    fun answered(previous: Snapshot, current: Snapshot): Boolean {
        if (previous.key != current.key) return false
        val importanceDropped =
            previous.importance != null &&
                current.importance != null &&
                current.importance < previous.importance
        val movedToSilent =
            previous.channelId.hasPrefix(CHANNEL_VOIP_PREFIX) &&
                current.channelId.hasPrefix(CHANNEL_SILENT_PREFIX)
        return importanceDropped || movedToSilent
    }

    private fun String?.hasPrefix(prefix: String): Boolean = this?.startsWith(prefix) == true

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
