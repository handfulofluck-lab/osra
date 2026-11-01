package com.familyshield.agent.services

import android.app.Notification
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.service.notification.NotificationListenerService
import android.service.notification.NotificationListenerService.Ranking
import android.service.notification.NotificationListenerService.RankingMap
import android.service.notification.StatusBarNotification
import com.familyshield.agent.comms.CommsLogger
import com.familyshield.agent.data.ConsentState
import com.familyshield.agent.social.MonitoredApps
import com.familyshield.agent.social.NotificationCapturePolicy
import com.familyshield.agent.social.ScanQueuePolicy
import com.familyshield.agent.social.SocialScanQueue
import com.familyshield.agent.social.WhatsAppCallPolicy
import com.familyshield.agent.social.WhatsAppCallTracker
import dagger.hilt.android.AndroidEntryPoint
import javax.inject.Inject

/**
 * Plan 2.6 (second half), **Full build only** — see ADR-0016. This is the thin adapter the ADR
 * describes: it maps a `StatusBarNotification` to [NotificationCapturePolicy.Snapshot] and hands the
 * decision to the pure policy, then enqueues what the policy accepts into the existing scan queue with
 * `SOURCE_NOTIFICATION`. There is deliberately no logic here that the Play build lacks: the judgement
 * lives in `main`, and only the manifest declaration and this registration are flavor-specific, so the
 * Play artefact cannot receive a notification at all.
 *
 * **Roadmap 4.5 adds a second, content-free path:** a WhatsApp *call* is not scanned, it is a row in the
 * timeline. [WhatsAppCallTracker] turns the posted/changed/removed sequence into exactly one row per call and
 * this class buffers it through [CommsLogger], so a call survives an offline stretch like every other row and
 * is uploaded by the same flush. The call's **body is never read**: the snapshot carries the category, the
 * title (WhatsApp's own name for the caller) and the channel, and nothing else.
 *
 * The 5-second hold a refused call needs before it becomes an `unknown` row (no `missed_call` notice ever
 * arrives for an outgoing call) is a `Handler` timer here, because a timer is the platform's business. If the
 * service is destroyed inside those 5 seconds the row is lost; the cost is one row, and no wrong one.
 *
 * Consent (ADR-0008 §3) is checked before anything is read: a revoked agent keeps the listener bound
 * (the OS owns that switch) but records nothing.
 */
@AndroidEntryPoint
class NotificationCaptureService : NotificationListenerService() {

    @Inject lateinit var queue: SocialScanQueue
    @Inject lateinit var consentState: ConsentState
    @Inject lateinit var comms: CommsLogger

    private val tracker = WhatsAppCallTracker()
    private val handler = Handler(Looper.getMainLooper())

    /** Emits the held rows whose missed-notice window has run out, then re-arms for whatever is left. */
    private val settleRunnable = Runnable { settle() }

    override fun onNotificationPosted(sbn: StatusBarNotification, rankingMap: RankingMap) {
        if (!consentState.isPaused()) trackWhatsAppCall(sbn, rankingMap, removed = false)
        capture(sbn, removed = false)
    }

    override fun onNotificationRemoved(sbn: StatusBarNotification, rankingMap: RankingMap) {
        // The scan policy drops removals (a swipe is not a message), but the call is made so the rule is
        // exercised on the real path instead of only in the unit suite. A call removal is the opposite: it
        // is where the duration comes from, so it goes to the tracker first.
        if (!consentState.isPaused()) trackWhatsAppCall(sbn, rankingMap, removed = true)
        capture(sbn, removed = true)
    }

    override fun onDestroy() {
        handler.removeCallbacks(settleRunnable)
        super.onDestroy()
    }

    private fun capture(sbn: StatusBarNotification, removed: Boolean) {
        if (consentState.isPaused()) return
        val capture = NotificationCapturePolicy.decide(snapshotOf(sbn, removed)) ?: return
        queue.enqueue(
            app = capture.appKey,
            contact = capture.contact,
            text = capture.text,
            nowMs = if (capture.postedAtMs > 0L) capture.postedAtMs else System.currentTimeMillis(),
            source = ScanQueuePolicy.SOURCE_NOTIFICATION,
        )
    }

    /**
     * Roadmap 4.5: hand one WhatsApp notification to [WhatsAppCallTracker] and buffer whatever row it decides.
     *
     * The package is checked before anything else, so a notification from any other app costs one map lookup and
     * never reaches the call path.
     */
    private fun trackWhatsAppCall(sbn: StatusBarNotification, rankingMap: RankingMap?, removed: Boolean) {
        if (MonitoredApps.appKeyFor(sbn.packageName.orEmpty()) != WHATSAPP_KEY) return
        val now = System.currentTimeMillis()
        val snapshot = whatsAppSnapshotOf(sbn, rankingMap)
        val rows = if (removed) tracker.removed(snapshot.key, now) else tracker.posted(snapshot)
        rows.forEach { comms.recordCall(it, now) }
        scheduleSettle()
    }

    private fun scheduleSettle() {
        handler.removeCallbacks(settleRunnable)
        val deadline = tracker.nextDeadlineMs() ?: return
        handler.postDelayed(settleRunnable, (deadline - System.currentTimeMillis()).coerceAtLeast(0L))
    }

    private fun settle() {
        val now = System.currentTimeMillis()
        if (consentState.isPaused()) return
        tracker.settle(now).forEach { comms.recordCall(it, now) }
        scheduleSettle()
    }

    companion object {
        private const val WHATSAPP_KEY = "whatsapp"

        /** The platform-to-policy mapping ADR-0016 calls the only unverified line; kept tiny on purpose. */
        fun snapshotOf(sbn: StatusBarNotification, removed: Boolean = false): NotificationCapturePolicy.Snapshot {
            val n: Notification? = sbn.notification
            val extras: Bundle? = n?.extras
            val isSummary = n != null && (n.flags and Notification.FLAG_GROUP_SUMMARY) != 0
            return NotificationCapturePolicy.Snapshot(
                packageId = sbn.packageName.orEmpty(),
                key = sbn.key.orEmpty(),
                isGroupSummary = isSummary,
                groupKey = n?.group,
                title = extras?.getCharSequence(Notification.EXTRA_TITLE)?.toString(),
                text = extras?.getCharSequence(Notification.EXTRA_TEXT)?.toString(),
                bigText = extras?.getCharSequence(Notification.EXTRA_BIG_TEXT)?.toString(),
                messages = messageLines(extras),
                isRemoved = removed,
                postedAtMs = sbn.postTime,
            )
        }

        /**
         * Roadmap 4.5: the fields a call needs — **no text, no big text, no messages**, so the call path cannot
         * carry content even by accident. `importance` and `channelId` are the two signals the Flip4 capture
         * showed for "answered"; both may be absent, and the tracker then falls back to the unknown row.
         */
        fun whatsAppSnapshotOf(
            sbn: StatusBarNotification,
            rankingMap: RankingMap? = null,
        ): WhatsAppCallPolicy.Snapshot {
            val n: Notification? = sbn.notification
            val ranking = Ranking()
            val ranked = rankingMap?.getRanking(sbn.key.orEmpty(), ranking) == true
            return WhatsAppCallPolicy.Snapshot(
                packageId = sbn.packageName.orEmpty(),
                key = sbn.key.orEmpty(),
                category = n?.category,
                title = n?.extras?.getCharSequence(Notification.EXTRA_TITLE)?.toString(),
                postedAtMs = sbn.postTime,
                // `getUser()` is a `UserHandle` whose `getIdentifier()` is not in the public SDK, so the profile
                // id is read from the key's first field — the same string the row's identity already uses.
                userId = userOf(sbn.key),
                importance = if (ranked) ranking.importance else null,
                // API 26 is the minimum, so the channel is always there; a null still means "not told".
                channelId = n?.channelId,
            )
        }

        /**
         * The Android profile a notification belongs to, from the first field of its key.
         *
         * `StatusBarNotification.getKey()` is `user|package|id|tag|uid` on the platform, and
         * `UserHandle.getIdentifier()` is not in the public SDK — so the key, which is already the row's
         * identity, is also where the profile comes from. Pairing a missed notice with its ring needs it; a
         * missing or unparsable field is treated as the main profile rather than dropping the call.
         */
        private fun userOf(key: String?): Int = key?.substringBefore('|')?.toIntOrNull() ?: 0

        /**
         * `EXTRA_MESSAGES` is a list of `Notification.MessagingStyle.Message` on modern APIs and a list
         * of `CharSequence` on older ones; both are handled because One UI and older sender apps still
         * produce the latter.
         */
        @Suppress("DEPRECATION")
        private fun messageLines(extras: Bundle?): List<String?> {
            val raw = extras?.get(Notification.EXTRA_MESSAGES) ?: return emptyList()
            if (raw !is List<*>) return emptyList()
            return raw.mapNotNull { item ->
                when (item) {
                    is Notification.MessagingStyle.Message -> item.text?.toString()
                    is CharSequence -> item.toString()
                    else -> null
                }
            }
        }
    }
}
