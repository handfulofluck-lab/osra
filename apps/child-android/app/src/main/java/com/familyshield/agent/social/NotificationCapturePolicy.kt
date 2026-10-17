package com.familyshield.agent.social

/**
 * Plan 2.6, second half — the decisions a notification capture has to make, as a pure function.
 *
 * Android delivers the same notification over and over (every update), plus a group summary that
 * repeats its children, plus "3 new messages" placeholders, plus removals when the user swipes it
 * away or the sender deletes it. Scanning all of that would send the parent duplicate and empty
 * rows, so the judgement lives here where it can be tested case by case, and
 * [com.familyshield.agent.services.NotificationCaptureService] is the thin adapter that feeds it.
 *
 * [Snapshot] is the subset of `StatusBarNotification` this needs, as primitives: the unit suite has
 * no Robolectric, and a test that builds a snapshot is exactly as honest as one that builds the
 * platform object — the only unverified line is the field mapping in the adapter, which
 * `assembleDebug` and the hardware row cover.
 */
object NotificationCapturePolicy {

    /** The fields of a posted/removed notification that decide whether it is worth a scan. */
    data class Snapshot(
        val packageId: String,
        /** `StatusBarNotification.key` — stable for the same notification across updates. */
        val key: String,
        val isGroupSummary: Boolean = false,
        val groupKey: String? = null,
        val title: String? = null,
        val text: String? = null,
        val bigText: String? = null,
        /** `MessagingStyle` lines, oldest first, when the app used that style (WhatsApp does). */
        val messages: List<String?> = emptyList(),
        /** True when this snapshot came from `onNotificationRemoved`. */
        val isRemoved: Boolean = false,
        val postedAtMs: Long = 0L,
    )

    /** One thing worth scanning: the app key the backend knows, the sender, and the newest line. */
    data class Capture(val appKey: String, val contact: String?, val text: String, val key: String, val postedAtMs: Long)

    /**
     * Returns the capture to enqueue, or null when the notification carries nothing to scan.
     *
     * The order of the checks is the point: a cheap identity check first (is the app monitored at
     * all), then the structural ones (removal, group summary), then the text extraction, so a
     * "3 new messages" summary never reaches the queue even if its wording changes.
     */
    fun decide(snapshot: Snapshot): Capture? {
        val appKey = MonitoredApps.appKeyFor(snapshot.packageId) ?: return null
        if (snapshot.isRemoved) return null
        // A group summary repeats its children's text — enqueuing it too is how a parent gets two
        // alerts for one message, which is the failure mode this whole class exists to prevent.
        if (snapshot.isGroupSummary) return null
        val (contact, body) = ScanQueuePolicy.fromNotification(
            snapshot.title,
            snapshot.text,
            snapshot.bigText,
            // Snapshot keeps primitives (it is built from a Bundle in an Android-free unit suite);
            // fromNotification takes CharSequence, so the upcast is explicit rather than positional.
            snapshot.messages.map { it as CharSequence? },
        ) ?: return null
        return Capture(appKey = appKey, contact = contact, text = body, key = snapshot.key, postedAtMs = snapshot.postedAtMs)
    }
}
