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
 * channels and gaps — with made-up names.
 *
 * **Every scenario below sums every list the tracker returns** across the whole sequence (ring, change, removal,
 * missed notice, settle) and asserts the total is one. That is the row for the #532 review's blocker: the earlier
 * version asserted `posted(ring()).single()` and so encoded "a row at the ring **and** a row at the end", which
 * put the same call on the parent's timeline twice with nothing downstream to merge it.
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
    private fun inProgress(at: Long = ringAt + 1_700L, key: String = keyFor(23), user: Int = 0) =
        snapshot(key = key, at = at, importance = 2, channel = "silent_notifications_3", user = user)

    /** The missed notice: a different notification id, posted about 1.2 s after the heads-up is removed. */
    private fun missedNotice(at: Long = ringAt + 30_243L, key: String = keyFor(4), pkg: String = whatsapp) =
        snapshot(
            key = key,
            category = WhatsAppCallPolicy.CATEGORY_MISSED_CALL,
            at = at,
            importance = 4,
            channel = "individual_chat_defaults_1",
            pkg = pkg,
        )

    @Test
    fun `(a) ring, answered, removed is one row, dated to the ring and measured from the answer`() {
        val tracker = WhatsAppCallTracker()
        val rows = mutableListOf<WhatsAppCallPolicy.Call>()
        rows += tracker.posted(ring(), ringAt)
        // 10:42:19.995 in the capture: the change that answers it, and the start of the length.
        rows += tracker.posted(inProgress(), ringAt + 1_700L)
        // 10:42:57.401: removed. 39.147 s after the ring, 37.447 s after the answer.
        rows += tracker.removed(keyFor(23), ringAt + 39_147L)
        rows += tracker.settle(ringAt + 120_000L)

        assertEquals("one call, one row", 1, rows.size)
        val row = rows.single()
        assertEquals("Mama", row.contact)
        assertEquals(WhatsAppCallPolicy.DIRECTION_UNKNOWN, row.direction)
        assertEquals("the length starts when it was answered, not when it rang", 37L, row.durationSec)
        assertTrue("measured from notifications, not timed", row.durationApprox)
        assertEquals("but the row is dated to the ring", ringAt, row.startMs)
        assertNull("nothing is left to settle", tracker.nextDeadlineMs())
    }

    @Test
    fun `(b) an unanswered ring plus a missed notice is one missed row, paired by package and time not by key`() {
        val tracker = WhatsAppCallTracker()
        val rows = mutableListOf<WhatsAppCallPolicy.Call>()
        rows += tracker.posted(ring(), ringAt)
        // 10:42:02.930 — no row yet, the notice decides.
        rows += tracker.removed(keyFor(23), ringAt + 29_040L)
        assertEquals(ringAt + 29_040L + WhatsAppCallPolicy.MISSED_PAIRING_WINDOW_MS, tracker.nextDeadlineMs())

        // The notice is a **different** notification id (4, not 23) 1.2 s later. Pairing on key would fail here.
        rows += tracker.posted(missedNotice(), ringAt + 30_243L)

        assertEquals("one call, one row", 1, rows.size)
        val row = rows.single()
        assertEquals(WhatsAppCallPolicy.DIRECTION_MISSED, row.direction)
        assertNull("a missed call has no length", row.durationSec)

        // And the held removal is gone: settling later must not add a phantom second row.
        assertNull(tracker.nextDeadlineMs())
        assertTrue(tracker.settle(ringAt + 120_000L).isEmpty())
    }

    @Test
    fun `(c) a call removed unanswered with no notice still emits one unknown row, never a duration`() {
        // Claude's finding: the outgoing call was posted and removed 25 s later with no change and no notice.
        // Before this row, the child's outgoing call left no row at all.
        val tracker = WhatsAppCallTracker()
        val rows = mutableListOf<WhatsAppCallPolicy.Call>()
        rows += tracker.posted(ring(), ringAt)
        rows += tracker.removed(keyFor(23), ringAt + 25_081L)
        assertTrue(
            "the row is held for the notice, not dropped and not emitted early",
            tracker.settle(ringAt + 25_081L + WhatsAppCallPolicy.MISSED_PAIRING_WINDOW_MS - 1L).isEmpty(),
        )
        rows += tracker.settle(ringAt + 25_081L + WhatsAppCallPolicy.MISSED_PAIRING_WINDOW_MS)

        assertEquals("one call, one row", 1, rows.size)
        val row = rows.single()
        assertEquals(WhatsAppCallPolicy.DIRECTION_UNKNOWN, row.direction)
        assertNull("we cannot tell whether it connected, so there is no length", row.durationSec)
        assertEquals("dated to when it rang, not to the timeout", ringAt, row.startMs)
        assertTrue("one row, once", tracker.settle(ringAt + 600_000L).isEmpty())
    }

    @Test
    fun `(d) a call on the Dual Messenger clone in user 95 is a row, not a filtered one`() {
        // Claude's rule 4: never filter to user 0. The user id is already inside the key.
        val tracker = WhatsAppCallTracker()
        val cloneKey = keyFor(23, user = 95)
        val rows = mutableListOf<WhatsAppCallPolicy.Call>()
        rows += tracker.posted(ring(key = cloneKey, user = 95), ringAt)
        rows += tracker.removed(cloneKey, ringAt + 12_000L)
        assertNotNull("unanswered, so held — but tracked, not dropped", tracker.nextDeadlineMs())

        // A missed notice on the *main* profile is not evidence about the clone: pairing is package + user. It is
        // its own call's row, so it is not counted in the clone's total.
        val mainProfile = tracker.posted(missedNotice(at = ringAt + 12_500L), ringAt + 12_500L)
        assertEquals("the notice belongs to the main profile's own call", 1, mainProfile.size)
        rows += tracker.settle(ringAt + 17_000L)

        assertEquals("one call, one row", 1, rows.size)
        assertEquals(WhatsAppCallPolicy.DIRECTION_UNKNOWN, rows.single().direction)
        assertNull(rows.single().durationSec)
    }

    @Test
    fun `(e) answered is detected by the channel prefix when the platform reports no importance`() {
        // Claude's rule 1: match the channel on its prefix, because `_4` and `_3` are numeric and move.
        val tracker = WhatsAppCallTracker()
        val rows = mutableListOf<WhatsAppCallPolicy.Call>()
        rows += tracker.posted(ring().copy(importance = null), ringAt)
        rows += tracker.posted(inProgress().copy(importance = null), ringAt + 1_700L)
        rows += tracker.removed(keyFor(23), ringAt + 35_000L)

        assertEquals("one call, one row", 1, rows.size)
        assertEquals(33L, rows.single().durationSec)
        assertTrue(rows.single().durationApprox)
    }

    @Test
    fun `(f) a re-post that changes nothing is not an answer`() {
        // The capture's outgoing call carried FOREGROUND_SERVICE from its first row, so a flag is not the
        // signal. A repeat of the same importance on the same channel means we learned nothing.
        val tracker = WhatsAppCallTracker()
        val rows = mutableListOf<WhatsAppCallPolicy.Call>()
        rows += tracker.posted(ring(), ringAt)
        rows += tracker.posted(snapshot(at = ringAt + 2_000L, importance = 4, channel = "voip_notification_4"), ringAt + 2_000L)
        rows += tracker.removed(keyFor(23), ringAt + 25_000L)
        rows += tracker.settle(ringAt + 30_000L)

        assertEquals("one call, one row", 1, rows.size)
        assertEquals(WhatsAppCallPolicy.DIRECTION_UNKNOWN, rows.single().direction)
        assertNull(rows.single().durationSec)
    }

    @Test
    fun `(g) the deadline is the earliest held removal plus the window, and null when nothing is held`() {
        val tracker = WhatsAppCallTracker()
        assertNull(tracker.nextDeadlineMs())
        assertTrue("a ring alone emits nothing", tracker.posted(ring(key = keyFor(23)), ringAt).isEmpty())
        assertTrue(
            "nor does a live call",
            tracker.posted(ring(key = keyFor(31), at = ringAt + 60_000L), ringAt + 60_000L).isEmpty(),
        )
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
        val rows = mutableListOf<WhatsAppCallPolicy.Call>()
        rows += tracker.posted(ring(), ringAt)
        rows += tracker.removed(keyFor(23), ringAt + 29_040L)
        rows += tracker.posted(
            missedNotice(at = ringAt + 30_000L, key = "0|org.telegram.messenger|4|null|1", pkg = "org.telegram.messenger"),
            ringAt + 30_000L,
        )
        rows += tracker.settle(ringAt + 40_000L)

        assertEquals("one call, one row", 1, rows.size)
        assertEquals(WhatsAppCallPolicy.DIRECTION_UNKNOWN, rows.single().direction)
        assertNull(rows.single().durationSec)
    }

    @Test
    fun `(i) one call is one identity even across its three notifications`() {
        val tracker = WhatsAppCallTracker()
        val ringCall = WhatsAppCallPolicy.started(ring())!!
        tracker.posted(ring(), ringAt)
        tracker.posted(inProgress(), ringAt + 1_700L)
        val ended = tracker.removed(keyFor(23), ringAt + 39_147L).single()
        assertEquals(WhatsAppCallPolicy.identity(ringCall), WhatsAppCallPolicy.identity(ended))
    }

    @Test
    fun `(j) nothing is emitted until the call ends`() {
        // The blocker from the #532 review in one row: a ring and its answer produce no rows at all.
        val tracker = WhatsAppCallTracker()
        assertTrue(tracker.posted(ring(), ringAt).isEmpty())
        assertTrue(tracker.posted(inProgress(), ringAt + 1_700L).isEmpty())
        assertNull("and nothing is waiting on a timer either", tracker.nextDeadlineMs())
        assertEquals(1L, tracker.removed(keyFor(23), ringAt + 20_000L).size.toLong())
    }
}
