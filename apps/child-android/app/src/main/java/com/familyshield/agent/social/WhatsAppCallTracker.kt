package com.familyshield.agent.social

import com.familyshield.agent.social.WhatsAppCallPolicy.Call
import com.familyshield.agent.social.WhatsAppCallPolicy.Snapshot

/**
 * Roadmap 4.5, the wiring half — the **order** of a WhatsApp call, as a pure object.
 *
 * [WhatsAppCallPolicy] decides what one notification means. This decides what the sequence means, because the
 * phone reports a call as several notifications that are not obviously one call, and the parent must get one
 * row per call, not one per notification:
 *
 * - a ring is posted, then the **same key** changes when the call is answered, then it is removed. **One row is
 *   written, and it is written at the end**: a live call has no length yet, and a row at the ring plus a row at
 *   the end would put the same call on the parent's timeline twice. Nothing downstream collapses the two —
 *   `POST /v1/devices/:id/activity` is a plain `createMany` and the payload carries no key — so the row is
 *   emitted once, when the call ends, as `ended`, `missed` or the settled `unknown`;
 * - **the length starts when the call was answered, not when it rang.** A call that rings for 25 s and then
 *   talks for 10 s lasted 10 s, so the duration is removal − answer-change, while the row stays dated to the
 *   ring so the timeline says when the phone rang;
 * - a ring that is never answered is removed **before** its `missed_call` notice arrives (~1.2 s later on the
 *   Flip4, Claude's capture). The notice is a **different key**, so the two are paired on the package, the
 *   Android user and the timing, never on key, and the ring is held for [missedWindowMs] waiting for it. That
 *   hold is why an ignored call is one missed row instead of a missed row plus a phantom "ended" one;
 * - a call that is removed unanswered and with **no** notice (the capture's outgoing call) still leaves exactly
 *   one row: `unknown` direction and no duration ([WhatsAppCallPolicy.unanswered]), emitted when the hold
 *   expires;
 * - **the user is never filtered.** The key already carries the Android user (`0|com.whatsapp|23|null|10406`), so
 *   a call to the Dual-Messenger clone in user 95 is a row exactly like a call to the main profile.
 *
 * The adapter owns the clock and the platform: it calls [posted] and [removed] as notifications arrive, then
 * [settle] at [nextDeadlineMs]. Everything here is a function of what it was told, so the whole sequence is a
 * JVM test.
 *
 * Known limits, stated rather than hidden. **A call is lost if the service is destroyed mid-call**, because the
 * row is written at the end and the state is in memory — the same accepted cost as the 5 s hold, and it costs a
 * row rather than a wrong one. Two calls at once from the same contact share one key, so an unanswered ring whose
 * removal was never delivered would merge into the next call; that needs two simultaneous calls from the same
 * person, and it costs a detail, never a content leak.
 */
class WhatsAppCallTracker(
    private val missedWindowMs: Long = WhatsAppCallPolicy.MISSED_PAIRING_WINDOW_MS,
) {

    /** A call that is ringing or in progress: the row is written when it ends, not when it rings. */
    private class Live(val posted: Snapshot, val call: Call) {
        var answered: Boolean = false

        /** When the change that answered the call was seen; the length is measured from here. */
        var answeredAtMs: Long? = null
    }

    /** A call removed unanswered, holding the slot for a `missed_call` notice before we invent a row. */
    private class Held(val packageId: String, val userId: Int, val call: Call, val removedAtMs: Long)

    private val live = LinkedHashMap<String, Live>()
    private val held = LinkedHashMap<String, Held>()

    /**
     * A notification was posted (or updated) while it is in the shade.
     *
     * Returns a row only for a **missed notice**, which is the end of its call. A ring returns nothing: the
     * parent gets one row per call and it is written when the call ends, because a row now and a row at the end
     * would be two rows for one call and nothing downstream merges them.
     *
     * @param nowMs when this notification was seen — the adapter's clock, used as the moment the call was
     *   answered so the length starts there rather than at the ring. Defaults to the notification's own post
     *   time, which is the same instant on the real path.
     */
    fun posted(snapshot: Snapshot, nowMs: Long = snapshot.postedAtMs): List<Call> {
        val started = WhatsAppCallPolicy.started(snapshot)
        if (started != null) {
            val existing = live[snapshot.key]
            if (existing == null) {
                live[snapshot.key] = Live(snapshot, started)
            } else if (!existing.answered && WhatsAppCallPolicy.answered(existing.posted, snapshot)) {
                // The ring became the ongoing row: the call is answered, and this is when its length starts.
                existing.answered = true
                existing.answeredAtMs = nowMs
            }
            return emptyList()
        }
        val missed = WhatsAppCallPolicy.missed(snapshot) ?: return emptyList()
        releaseForMissed(snapshot)
        return listOf(missed)
    }

    /**
     * The heads-up for [key] was removed at [removedAtMs].
     *
     * An answered call produces its row here, with the length. An unanswered one produces nothing yet: it is
     * held for a `missed_call` notice, and [settle] writes the unknown row if none arrives.
     */
    fun removed(key: String, removedAtMs: Long): List<Call> {
        val entry = live.remove(key) ?: return emptyList()
        // The removal is dated by us and the contact comes from the ring: `onNotificationRemoved` may carry a
        // notification whose title has already been cleared, and a call with no name is not a row.
        val ended = WhatsAppCallPolicy.ended(
            snapshot = entry.posted,
            startedAtMs = entry.call.startMs,
            answered = entry.answered,
            removedAtMs = removedAtMs,
            // The ring does not count: a call that rang 25 s and talked 10 s lasted 10 s. Falls back to the ring
            // only if the platform answered without ever telling us it changed, which the capture never showed.
            answeredAtMs = entry.answeredAtMs ?: entry.call.startMs,
        )
        if (ended != null) return listOf(ended)
        held[key] = Held(entry.posted.packageId, entry.posted.userId, entry.call, removedAtMs)
        return emptyList()
    }

    /**
     * Emit the rows whose missed-notice window has run out — the outgoing-call case, and any call the notice
     * never came for. Call it at [nextDeadlineMs]; calling it at any other time is harmless and returns nothing
     * that is not yet due.
     */
    fun settle(nowMs: Long): List<Call> {
        val due = held.entries.filter { nowMs - it.value.removedAtMs >= missedWindowMs }.map { it.key }
        if (due.isEmpty()) return emptyList()
        val out = ArrayList<Call>(due.size)
        for (key in due) {
            val entry = held.remove(key) ?: continue
            out += WhatsAppCallPolicy.unanswered(entry.call)
        }
        return out
    }

    /** When [settle] next has work, or null when nothing is held. The adapter schedules exactly one timer. */
    fun nextDeadlineMs(): Long? = held.values.minOfOrNull { it.removedAtMs + missedWindowMs }

    /**
     * Drop whatever is holding a slot for [missed]: a held removal first (paired on package and timing), then a
     * still-live unanswered call from the same package, which is the same situation when the removal was never
     * delivered. Never on key: the notice is a different notification.
     */
    private fun releaseForMissed(missed: Snapshot) {
        val heldKey = held.entries.firstOrNull { (_, entry) ->
            entry.packageId == missed.packageId &&
                entry.userId == missed.userId &&
                missed.postedAtMs - entry.removedAtMs in 0..missedWindowMs
        }?.key
        if (heldKey != null) {
            held.remove(heldKey)
            return
        }
        val orphanKey = live.entries.firstOrNull { (_, entry) ->
            !entry.answered &&
                entry.posted.packageId == missed.packageId &&
                entry.posted.userId == missed.userId &&
                entry.call.startMs <= missed.postedAtMs
        }?.key
        if (orphanKey != null) live.remove(orphanKey)
    }
}
