package com.familyshield.agent.services

import android.app.Notification
import android.os.Bundle
import android.service.notification.NotificationListenerService
import android.service.notification.StatusBarNotification
import com.familyshield.agent.data.ConsentState
import com.familyshield.agent.social.NotificationCapturePolicy
import com.familyshield.agent.social.ScanQueuePolicy
import com.familyshield.agent.social.SocialScanQueue
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
 * Consent (ADR-0008 §3) is checked before anything is read: a revoked agent keeps the listener bound
 * (the OS owns that switch) but records nothing.
 */
@AndroidEntryPoint
class NotificationCaptureService : NotificationListenerService() {

    @Inject lateinit var queue: SocialScanQueue
    @Inject lateinit var consentState: ConsentState

    override fun onNotificationPosted(sbn: StatusBarNotification, rankingMap: RankingMap) {
        capture(sbn, removed = false)
    }

    override fun onNotificationRemoved(sbn: StatusBarNotification, rankingMap: RankingMap) {
        // The policy drops removals (a swipe is not a message), but the call is made so the rule is
        // exercised on the real path instead of only in the unit suite.
        capture(sbn, removed = true)
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

    companion object {
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
