package com.familyshield.agent.social

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Roadmap 4.5, the parser half: a WhatsApp call becomes a call row — who, when, roughly how long, never
 * content, and never a direction we cannot prove. Claude's faults for this item are the rows below; the
 * three this object cannot own are named at the bottom so a green suite is not read as covering them.
 */
class WhatsAppCallPolicyTest {

    private val start = 1_792_563_200_000L

    private fun snapshot(
        key: String = "whatsapp-call-1",
        category: String? = WhatsAppCallPolicy.CATEGORY_CALL,
        title: String? = "Mama",
        at: Long = start,
        pkg: String = "com.whatsapp",
        importance: Int? = null,
        channel: String? = null,
    ) = WhatsAppCallPolicy.Snapshot(
        packageId = pkg,
        key = key,
        category = category,
        title = title,
        postedAtMs = at,
        importance = importance,
        channelId = channel,
    )

    @Test
    fun `a ringing call is a call with no direction and no duration yet`() {
        // Claude's point 2: WhatsApp keeps an ongoing-call notification for outgoing calls too, so
        // "incoming" would be a false statement about the child. The arrow is lost on purpose.
        val row = WhatsAppCallPolicy.started(snapshot())!!
        assertEquals("Mama", row.contact)
        assertEquals(WhatsAppCallPolicy.DIRECTION_UNKNOWN, row.direction)
        assertNull("we have not timed it yet", row.durationSec)
        assertFalse("and we must not claim a measurement", row.durationApprox)
    }

    @Test
    fun `a message notification is not a call`() {
        // Claude's fault 1, the main one: every WhatsApp message also carries the sender in the title, so
        // without the category a chat message would become "a call from Mama".
        val message = snapshot(category = "msg")
        assertNull(WhatsAppCallPolicy.started(message))
        assertNull(WhatsAppCallPolicy.ended(message, start, answered = true))
        assertNull(WhatsAppCallPolicy.missed(message))
        // And a notification with no category at all is not guessed at either.
        assertNull(WhatsAppCallPolicy.started(snapshot(category = null)))
    }

    @Test
    fun `an answered call carries an approximate duration`() {
        val row = WhatsAppCallPolicy.ended(snapshot(at = start + 92_000L), start, answered = true)!!
        assertEquals("Mama", row.contact)
        assertEquals(92L, row.durationSec)
        assertTrue("notification timing, not a stopwatch", row.durationApprox)
        assertEquals("the start is the heads-up, not the removal", start, row.startMs)
    }

    @Test
    fun `an unanswered call produces no ended row, so the missed notice owns it`() {
        // Claude's point 3: ring, remove, then a missed notice. Without this, the removal claims 25 seconds
        // of call and the missed notice adds a second row for the same nothing.
        assertNull(WhatsAppCallPolicy.ended(snapshot(at = start + 25_000L), start, answered = false))
    }

    @Test
    fun `a missed call carries direction missed and no duration at all`() {
        // Claude's fault 2: a missed call with a duration. Null, not 0.
        val row = WhatsAppCallPolicy.missed(
            snapshot(category = WhatsAppCallPolicy.CATEGORY_MISSED_CALL, at = start + 30_000L),
        )!!
        assertEquals(WhatsAppCallPolicy.DIRECTION_MISSED, row.direction)
        assertNull(row.durationSec)
        assertFalse(row.durationApprox)
    }

    @Test
    fun `the notification body cannot reach the row, because there is nowhere to put it`() {
        // Claude's point 4: `text` is gone from Snapshot, so the body never enters the parser. This row keeps
        // the property visible: only the caller name survives.
        val row = WhatsAppCallPolicy.started(snapshot(title = "Mama"))!!
        assertEquals("Mama", row.contact)
        assertFalse(
            "no field of the row may carry anything but the name",
            listOf(row.contact, row.direction, row.key).any { it.length > 40 },
        )
    }

    @Test
    fun `another app, an unnamed call, a backwards clock and a wild one are refused or bounded`() {
        assertNull(WhatsAppCallPolicy.started(snapshot(pkg = "org.telegram.messenger")))
        assertNull(WhatsAppCallPolicy.started(snapshot(pkg = "com.android.dialer")))
        assertNull(WhatsAppCallPolicy.started(snapshot(title = "   ")))
        assertEquals(
            0L,
            WhatsAppCallPolicy.ended(snapshot(at = start - 5_000L), start, answered = true)!!.durationSec,
        )
        assertEquals(
            24L * 60 * 60,
            WhatsAppCallPolicy.ended(
                snapshot(at = start + 48L * 60 * 60 * 1000), start, answered = true,
            )!!.durationSec,
        )
    }

    @Test
    fun `WhatsApp Business is the same app key`() {
        assertEquals("Mama", WhatsAppCallPolicy.started(snapshot(pkg = "com.whatsapp.w4b"))!!.contact)
    }

    @Test
    fun `one call has one identity`() {
        // This pins `identity()`; the *re-post* itself is the adapter's job — it keeps the first `startMs`
        // per notification key, and the wiring PR carries the real ring → in progress → removed row.
        val ring = WhatsAppCallPolicy.started(snapshot(at = start))!!
        val ended = WhatsAppCallPolicy.ended(snapshot(at = start + 40_000L), start, answered = true)!!
        assertEquals(WhatsAppCallPolicy.identity(ring), WhatsAppCallPolicy.identity(ended))
        assertTrue(
            "two calls from the same person in the same second stay two",
            WhatsAppCallPolicy.identity(ended) !=
                WhatsAppCallPolicy.identity(ended.copy(key = "whatsapp-call-2")),
        )
        assertTrue(
            "a later call that reuses the notification key is a new call",
            WhatsAppCallPolicy.identity(ended) !=
                WhatsAppCallPolicy.identity(ended.copy(startMs = start + 3_600_000L)),
        )
    }

    @Test
    fun `an unanswered call that ends anyway becomes one unknown row with no length`() {
        // Claude's gap: the capture's outgoing call was removed with no change and no missed notice. A duration
        // here would be the ring time, which says the call connected — we cannot know that.
        val ring = WhatsAppCallPolicy.started(snapshot())!!
        val row = WhatsAppCallPolicy.unanswered(ring)
        assertEquals(ring.contact, row.contact)
        assertEquals(ring.key, row.key)
        assertEquals(ring.startMs, row.startMs)
        assertEquals(WhatsAppCallPolicy.DIRECTION_UNKNOWN, row.direction)
        assertNull(row.durationSec)
        assertFalse("nothing was measured", row.durationApprox)
    }

    @Test
    fun `the end is dated by the removal, not by the notification's own post time`() {
        // A removal carries the time the notification was POSTED, so reading the duration off it reports 0 s for
        // every call. The removal time is a separate fact and is passed separately.
        val row = WhatsAppCallPolicy.ended(
            snapshot(at = start),
            startedAtMs = start,
            answered = true,
            removedAtMs = start + 92_000L,
        )!!
        assertEquals(92L, row.durationSec)
    }

    @Test
    fun `answered is the same key changing, and a different key never is`() {
        val ring = snapshot(importance = 4, channel = "voip_notification_4")
        val inProgress = snapshot(importance = 2, channel = "silent_notifications_3")
        assertTrue(WhatsAppCallPolicy.answered(ring, inProgress))
        assertTrue(
            "the channel alone is enough, matched on its prefix",
            WhatsAppCallPolicy.answered(ring.copy(importance = null), inProgress.copy(importance = null)),
        )
        assertTrue(
            "the importance alone is enough",
            WhatsAppCallPolicy.answered(ring.copy(channelId = null), inProgress.copy(channelId = null)),
        )
        assertFalse(
            "a re-post that changes nothing is not an answer",
            WhatsAppCallPolicy.answered(ring, ring.copy(postedAtMs = start + 2_000L)),
        )
        assertFalse(
            "another notification is another call",
            WhatsAppCallPolicy.answered(ring, inProgress.copy(key = "whatsapp-call-2")),
        )
    }

    // What this suite cannot own, stated so a green run is not read as more than it is:
    //  - fault 1 (pause gate): the gate lives in the capture service; the row belongs there.
    //  - fault 6 (Play flavour captures calls): a build-flavour question, for the manifest/flavour tests.
    //  - fault 7 (a row without `source` shown as WhatsApp): server payload plus parent-app rendering — the
    //    payload half is pinned in `CommsCallPayloadTest`, the rendering half in `call_rows_45_test.dart`.
    //  - the real sequence (ring, answer, end, missed, outgoing): the tracker's rows use Claude's Flip4
    //    capture as their fixture, but delivery to our own listener is still owed on the phone.
}
