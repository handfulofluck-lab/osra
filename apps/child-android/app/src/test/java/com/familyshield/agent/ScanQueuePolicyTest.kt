package com.familyshield.agent

import com.familyshield.agent.social.ScanQueuePolicy
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** Plan 2.6: the durable queue's give-up and retry rules. */
class ScanQueuePolicyTest {
    private val now = 10_000_000L

    @Test
    fun `a row is kept while it is young and under the attempt cap`() {
        assertTrue(ScanQueuePolicy.shouldKeep(attempts = 0, createdAtMs = now - 1000, nowMs = now))
        assertTrue(ScanQueuePolicy.shouldKeep(attempts = 7, createdAtMs = now - 1000, nowMs = now))
    }

    @Test
    fun `a row is dropped at the attempt cap or after two days`() {
        assertFalse(ScanQueuePolicy.shouldKeep(attempts = 8, createdAtMs = now - 1000, nowMs = now))
        assertFalse(ScanQueuePolicy.shouldKeep(attempts = 0, createdAtMs = now - ScanQueuePolicy.MAX_AGE_MS - 1, nowMs = now))
    }

    @Test
    fun `retry is scheduled only for network failures with rows left`() {
        assertTrue(ScanQueuePolicy.retryLater(anyNetworkFailure = true, remaining = 3))
        assertFalse(ScanQueuePolicy.retryLater(anyNetworkFailure = true, remaining = 0))
        assertFalse(ScanQueuePolicy.retryLater(anyNetworkFailure = false, remaining = 3))
    }

    @Test
    fun `batch size is bounded`() {
        assertEquals(50, ScanQueuePolicy.BATCH_SIZE)
    }

    @Test
    fun `housekeeping notifications never become captures`() {
        assertNull(ScanQueuePolicy.fromNotification("WhatsApp", "Checking for new messages", null, emptyList()))
        assertNull(ScanQueuePolicy.fromNotification("Sam", "", null, emptyList()))
    }

    @Test
    fun `a collapsed count placeholder is housekeeping, with or without a group name`() {
        // "3 new messages" defeats a literal list because none of its entries starts with a digit;
        // the shape is matched instead (plan 2.6, second half).
        assertNull(ScanQueuePolicy.fromNotification("WhatsApp", "3 new messages", null, emptyList()))
        assertNull(ScanQueuePolicy.fromNotification("Work", "12 new messages from Work", null, emptyList()))
        assertNull(ScanQueuePolicy.fromNotification("WhatsApp", "1 new message", null, emptyList()))
        // A real line that merely contains the words is still a message.
        assertEquals("Mum" to "I have 3 new messages for you", ScanQueuePolicy.fromNotification("Mum", "I have 3 new messages for you", null, emptyList()))
    }
}
