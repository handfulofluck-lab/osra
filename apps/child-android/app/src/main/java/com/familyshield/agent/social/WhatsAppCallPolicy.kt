package com.familyshield.agent.social

/**
 * Roadmap 4.5 — a WhatsApp call as a **call row**, never as content. The decisions, as a pure function.
 *
 * WhatsApp tells the phone three things about a call and nothing more: a heads-up while it rings, a
 * "missed call" notice when it was not answered, and (implicitly) that the heads-up went away when the call
 * ended. From those we can honestly report **who, when, and roughly how long** — and nothing else:
 *
 * - the caller name is the notification's title, because WhatsApp gives no number;
 * - an ongoing call is `incoming` (a call the child placed produces no heads-up notification, so a heads-up
 *   is never one they started — the one assumption here, stated rather than hidden);
 * - a duration is the difference between the heads-up and its removal, so it is **approximate**, and
 *   [Call.durationApprox] says so rather than letting the parent read it as a measured time;
 * - a missed call has **no** duration at all — not zero, absent ([Call.durationSec] is null), because "0 s"
 *   would read as an instantaneous call rather than one that never connected;
 * - the notification's **text is never read into the result**: [Call] has no field for it, so a future
 *   refactor cannot copy a message body into a call row by accident.
 *
 * The adapter (`NotificationCaptureService`, Full flavour only) owns the platform mapping and the pause
 * gate; this object only decides what a call looks like once the notification is in hand.
 */
object WhatsAppCallPolicy {

    /** The fields of a posted/removed call notification this needs, as primitives — no Android types. */
    data class Snapshot(
        val packageId: String,
        /** `StatusBarNotification.key`: stable across the updates of one call. */
        val key: String,
        /** WhatsApp puts the caller's display name here; it is the only identity we are given. */
        val title: String? = null,
        /** The notification body. Present so the mapping is honest about what arrives, **never** used. */
        val text: String? = null,
        /** True while the call is ringing or in progress; false once the notification is removed. */
        val isOngoing: Boolean = true,
        /** True when this snapshot is a "missed call" notice rather than a live call. */
        val isMissed: Boolean = false,
        val postedAtMs: Long = 0L,
    )

    /** One call row: who, when, how long — and nothing that could carry content. */
    data class Call(
        val contact: String,
        /** `incoming` or `missed`. A heads-up is never a call the child placed; see the class KDoc. */
        val direction: String,
        /** Seconds, or null when the call never connected. */
        val durationSec: Long?,
        /** True whenever [durationSec] is present: it is measured from notifications, not timed. */
        val durationApprox: Boolean,
        val startMs: Long,
        /** The notification key, for [identity]. */
        val key: String,
    )

    /**
     * The identity of one call: the notification key **plus** the start time.
     *
     * The key alone is not enough — WhatsApp reuses it — and the start alone is not enough either: two
     * missed calls from the same person in the same second are two calls. Together they make a re-posted
     * heads-up (ring → in progress → removed) one row, which is the difference between one call and four.
     */
    fun identity(call: Call): String = "${call.key}|${call.startMs}"

    /** The caller name, or null when WhatsApp gave us nothing to name. */
    private fun contactOf(snapshot: Snapshot): String? =
        snapshot.title?.trim()?.takeIf { it.isNotEmpty() }

    /** True when this notification is a WhatsApp call at all: the monitored app, and a name to show. */
    fun isCall(snapshot: Snapshot): Boolean =
        MonitoredApps.appKeyFor(snapshot.packageId) == "whatsapp" && contactOf(snapshot) != null

    /**
     * A call that is ringing or in progress: `incoming`, no duration yet.
     *
     * Returns null for a missed notice, for another app, and for a notification with no name — an unnamed
     * row ("Incoming call") tells the parent nothing they can act on.
     */
    fun started(snapshot: Snapshot): Call? {
        if (!isCall(snapshot) || snapshot.isMissed) return null
        return Call(
            contact = contactOf(snapshot)!!,
            direction = "incoming",
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
     */
    fun ended(snapshot: Snapshot, startedAtMs: Long): Call? {
        if (!isCall(snapshot) || snapshot.isMissed) return null
        // A clock that went backwards must not produce a negative duration or a wild one: a removal dated
        // before the start is "just started", and anything beyond a day is not a call we watched.
        val elapsedMs = (snapshot.postedAtMs - startedAtMs).coerceIn(0L, MAX_CALL_MS)
        return Call(
            contact = contactOf(snapshot)!!,
            direction = "incoming",
            durationSec = elapsedMs / 1_000L,
            durationApprox = true,
            startMs = startedAtMs,
            key = snapshot.key,
        )
    }

    /** A call that was never answered: `missed`, and **no** duration — null, not zero. */
    fun missed(snapshot: Snapshot): Call? {
        if (!isCall(snapshot) || !snapshot.isMissed) return null
        return Call(
            contact = contactOf(snapshot)!!,
            direction = "missed",
            durationSec = null,
            durationApprox = false,
            startMs = snapshot.postedAtMs,
            key = snapshot.key,
        )
    }

    /** A call longer than this is not one we watched end; 24 hours is generous and stops a wild number. */
    private const val MAX_CALL_MS = 24L * 60 * 60 * 1000
}
