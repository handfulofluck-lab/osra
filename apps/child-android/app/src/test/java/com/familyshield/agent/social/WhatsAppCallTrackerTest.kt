package com.familyshield.agent.social

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Roadmap 4.5, the wiring half: the **sequence** of a WhatsApp call becomes exactly one row.
 *
 * The fixtures are Claude's Flip4 capture (#50, comment 6556895749), field for field — the ids, importances,
 * channels and gaps — with made-up names. The four faults Claude named for this item are the four groups below:
 * the outgoing call dropped, the missed notice paired by key, a user-95 row filtered out, and the channel
 * matched exactly instead of by prefix.
 */
class WhatsAppCallTrackerTest {

    /** 10:41:33.890 UTC on 1 Nov 2026, the first row of the capture. */
    private val ringAt = 1_792_564_893_890L
    private val whatsapp = "com.whatsapp"

    /** `user|package|id|tag|uid` — the shape `StatusBarNotification.key` has on the phone. */
    private fun keyFor(notificationId: Int, user: Int = 0) = "$user|$whatsapp|$notificationId|null|10406"

    private fun snapshot(
        key: String = keyFor(23),
        category: String? = WhatsAppCallPolicy.CATEGORY_CALL,
        title: String? = "Mama",
        at: Long = ringAt,
        importance: Int? = 4,
        channel: String? = "voip_notification_4",
        pkg: String = whatsapp,
        user: Int = 0,
    ) = WhatsAppCallPolicy.Snapshot(
        packageId = pkg,
        key = key,
        category = category,
        title = title,
        postedAtMs = at,
        userId = user,
        importance = importance,
        channelId = channel,
    )

    /** The ring. */
    private fun ring(at: Long = ringAt, key: String = keyFor(23), user: Int = 0) =
        snapshot(key = key, at = at, user = user)

    /** The same key, second row of the answered call: importance 4 → 2 on the silent channel. */
    private fun inProgress(at: Long = ringAt + 1_700L, key: String = keyFor(23)) =
        snapshot(key = key, at = at, importance = 2, channel = "silent_notifications_3")

    @Test
    fun `(a) ring, answered, removed is one row with the length and no invented direction`() {
        val tracker = WhatsAppCallTracker()
        val ringRow = tracker.posted(ring()).single()
        assertEquals(WhatsAppCallPolicy.DIRECTION_UNKNOWN, ringRow.direction)
        assertNull(ringRow.durationSec)

        // The capture's answered call: 10:42:18.254 ring, 10:42:19.995 the change, 10:42:57.401 removed.
        assertTrue("the change is the same call, not a second row", tracker.posted(inProgress()).isEmpty())
        val ended = tracker.removed(ringRow.key, ringAt + 39_147L).single()
        assertEquals("Mama", ended.contact)
        assertEquals("removal minus heads-up, seconds", 39L, ended.durationSec)
        assertTrue("measured from notifications, not timed", ended.durationApprox)
        assertEquals("dated to the ring", ringAt, ended.startMs)
        assertNull("nothing is left to settle", tracker.nextDeadlineMs())
    }

    @Test
    fun `(b) an unanswered ring plus a missed notice is one missed row, paired by package and time not by key`() {
        val tracker = WhatsAppCallTracker()
        val ringRow = tracker.posted(ring()).single()
        // Removed unanswered at 10:42:02.930 — no row yet, the notice decides.
        assertTrue(tracker.removed(ringRow.key, ringAt + 29_040L).isEmpty())
        assertEquals(ringAt + 29_040L + WhatsAppCallPolicy.MISSED_PAIRING_WINDOW_MS, tracker.nextDeadlineMs())

        // The notice is a **different** notification id (4, not 23) 1.2 s later. Pairing on key would fail here.
        val missed = tracker.posted(
            snapshot(
                key = keyFor(4),
                category = WhatsAppCallPolicy.CATEGORY_MISSED_CALL,
                at = ringAt + 30_243L,
                importance = 4,
                channel = "individual_chat_defaults_1",
            ),
        ).single()
        assertEquals(WhatsAppCallPolicy.DIRECTION_MISSED, missed.direction)
        assertNull("a missed call has no length", missed.durationSec)

        // And the held removal is gone: settling later must not add a phantom second row.
        assertNull(tracker.nextDeadlineMs())
        assertTrue(tracker.settle(ringAt + 120_000L).isEmpty())
    }

    @Test
    fun `(c) a call removed unanswered with no notice still emits one unknown row, never a duration`() {
        // Claude's finding: the outgoing call was posted and removed 25 s later with no change and no notice.
        // Before this row, the child's outgoing call left no row at all.
        val tracker = WhatsAppCallTracker()
        val ringRow = tracker.posted(ring()).single()
        assertTrue(tracker.removed(ringRow.key, ringAt + 25_081L).isEmpty())

        assertTrue(
            "the row is held for the notice, not dropped and not emitted early",
            tracker.settle(ringAt + 25_081L + WhatsAppCallPolicy.MISSED_PAIRING_WINDOW_MS - 1L).isEmpty(),
        )
        val unknown = tracker.settle(ringAt + 25_081L + WhatsAppCallPolicy.MISSED_PAIRING_WINDOW_MS).single()
        assertEquals(WhatsAppCallPolicy.DIRECTION_UNKNOWN, unknown.direction)
        assertNull("we cannot tell whether it connected, so there is no length", unknown.durationSec)
        assertEquals(ringRow.key, unknown.key)
        assertEquals("dated to when it rang, not to the timeout", ringAt, unknown.startMs)
        assertTrue("one row, once", tracker.settle(ringAt + 600_000L).isEmpty())
    }

    @Test
    fun `(d) a call on the Dual Messenger clone in user 95 is a row, not a filtered one`() {
        // Claude's rule 4: never filter to user 0. The user id is already inside the key.
        val tracker = WhatsAppCallTracker()
        val cloneKey = keyFor(23, user = 95)
        val row = tracker.posted(ring(key = cloneKey, user = 95)).single()
        assertEquals(cloneKey, row.key)
        assertTrue(cloneKey.startsWith("95|"))
        val ended = tracker.removed(cloneKey, ringAt + 12_000L)
        assertTrue("unanswered, so held — but tracked, not dropped", ended.isEmpty())
        assertNotNull(tracker.nextDeadlineMs())

        // A missed notice on the *main* profile is not evidence about the clone: pairing is package + user.
        tracker.posted(
            snapshot(
                key = keyFor(4),
                category = WhatsAppCallPolicy.CATEGORY_MISSED_CALL,
                at = ringAt + 12_500L,
                channel = "individual_chat_defaults_1",
            ),
        )
        val unknown = tracker.settle(ringAt + 17_000L).single()
        assertEquals(WhatsAppCallPolicy.DIRECTION_UNKNOWN, unknown.direction)
        assertNull(unknown.durationSec)
    }

    @Test
    fun `(e) answered is detected by the channel prefix when the platform reports no importance`() {
        // Claude's rule 1: match the channel on its prefix, because `_4` and `_3` are numeric and move.
        val tracker = WhatsAppCallTracker()
        tracker.posted(ring().copy(importance = null))
        assertTrue(
            "voip_notification_4 -> silent_notifications_3 is the answer, on prefix and on a moving suffix",
            tracker.posted(inProgress().copy(importance = null)).isEmpty(),
        )
        val ended = tracker.removed(keyFor(23), ringAt + 35_000L).single()
        assertEquals(35L, ended.durationSec)
        assertTrue(ended.durationApprox)
    }

    @Test
    fun `(f) a re-post that changes nothing is not an answer`() {
        // The capture's outgoing call carried FOREGROUND_SERVICE from its first row, so a flag is not the
        // signal. A repeat of the same importance on the same channel means we learned nothing.
        val tracker = WhatsAppCallTracker()
        val ringRow = tracker.posted(ring()).single()
        assertTrue(
            tracker.posted(snapshot(at = ringAt + 2_000L, importance = 4, channel = "voip_notification_4"))
                .isEmpty(),
        )
        assertTrue("still unanswered, so no ended row", tracker.removed(ringRow.key, ringAt + 25_000L).isEmpty())
        val unknown = tracker.settle(ringAt + 30_000L).single()
        assertNull(unknown.durationSec)
    }

    @Test
    fun `(g) the deadline is the earliest held removal plus the window, and null when nothing is held`() {
        val tracker = WhatsAppCallTracker()
        assertNull(tracker.nextDeadlineMs())
        tracker.posted(ring(key = keyFor(23))).single()
        tracker.posted(ring(key = keyFor(31), at = ringAt + 60_000L)).single()
        assertNull("a live call is not waiting on anything", tracker.nextDeadlineMs())

        tracker.removed(keyFor(23), ringAt + 100_000L)
        tracker.removed(keyFor(31), ringAt + 130_000L)
        assertEquals(ringAt + 100_000L + WhatsAppCallPolicy.MISSED_PAIRING_WINDOW_MS, tracker.nextDeadlineMs())
        assertEquals(1L, tracker.settle(ringAt + 105_000L).size.toLong())
        assertEquals(ringAt + 130_000L + WhatsAppCallPolicy.MISSED_PAIRING_WINDOW_MS, tracker.nextDeadlineMs())
    }

    @Test
    fun `(h) a missed notice from another package does not close a WhatsApp call`() {
        // Pairing is on package *and* timing; a Telegram "missed call" is not evidence about WhatsApp.
        val tracker = WhatsAppCallTracker()
        val ringRow = tracker.posted(ring()).single()
        tracker.removed(ringRow.key, ringAt + 29_040L)
        tracker.posted(
            snapshot(
                key = "0|org.telegram.messenger|4|null|1",
                category = WhatsAppCallPolicy.CATEGORY_MISSED_CALL,
                at = ringAt + 30_000L,
                pkg = "org.telegram.messenger",
            ),
        )
        val unknown = tracker.settle(ringAt + 40_000L).single()
        assertEquals(WhatsAppCallPolicy.DIRECTION_UNKNOWN, unknown.direction)
        assertNull(unknown.durationSec)
    }

    @Test
    fun `(i) one call is one identity even across its three notifications`() {
        val tracker = WhatsAppCallTracker()
        val ringRow = tracker.posted(ring()).single()
        tracker.posted(inProgress())
        val ended = tracker.removed(ringRow.key, ringAt + 39_147L).single()
        assertEquals(WhatsAppCallPolicy.identity(ringRow), WhatsAppCallPolicy.identity(ended))
    }
}
