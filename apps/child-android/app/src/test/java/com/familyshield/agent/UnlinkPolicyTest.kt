package com.familyshield.agent

import com.familyshield.agent.network.DeviceRevoked
import com.familyshield.agent.network.UnlinkPolicy
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Issue #465: a phone whose family was deleted must stop enforcing and release itself, and must not do
 * that for anything less than a definite answer.
 *
 * The dangerous direction is the loose one: unlinking on a network blip would switch off a child's
 * protection with no parent to switch it back on. The other direction is the bug being fixed: the poll
 * threw on `401 device_revoked` and retried forever, so a deleted family's phone stayed locked with a
 * device-admin grant nobody could remove.
 */
class UnlinkPolicyTest {

    private val minute = 60_000L

    @Test
    fun `U1 one revoked answer does not unlink, a second one a minute later does`() {
        val policy = UnlinkPolicy()
        assertFalse("the first answer is not a confirmation", policy.onDeviceRevoked(0L))
        // Mutant: unlink on the first answer, and this row goes red — a single 401 could be a server bug.
        assertTrue(policy.onDeviceRevoked(minute))
        assertTrue(policy.isUnlinked())
    }

    @Test
    fun `U1b a second answer too soon keeps waiting, and keeps the original timestamp`() {
        val policy = UnlinkPolicy()
        assertFalse(policy.onDeviceRevoked(0L))
        // A flapping server answering twice quickly must not confirm, and must not restart the clock.
        assertFalse(policy.onDeviceRevoked(30_000L))
        assertEquals(0L, policy.pendingSinceMs())
        assertTrue(policy.onDeviceRevoked(minute))
    }

    @Test
    fun `U2 a 5xx, a network error or a plain 401 never counts`() {
        // The reader is the only thing that can let a bad answer through, so the negatives live here.
        assertFalse("a 5xx is a server problem, not a deletion", DeviceRevoked.isRevoked(500, DeviceRevoked.CODE))
        assertFalse("a plain 401 is what a token refresh fixes", DeviceRevoked.isRevoked(401, null))
        assertFalse("a different body code is a different problem", DeviceRevoked.isRevoked(401, "unauthorized"))
        assertFalse(DeviceRevoked.isRevoked(403, DeviceRevoked.CODE))
        // Mutant: unlink on any 401 (`status == 401` alone) and the two middle rows go red.
        assertTrue(DeviceRevoked.isRevoked(401, DeviceRevoked.CODE))
    }

    @Test
    fun `U2b the body reader takes the error code and nothing else`() {
        assertEquals(DeviceRevoked.CODE, DeviceRevoked.codeFromBody("""{"error":"device_revoked"}"""))
        assertEquals(DeviceRevoked.CODE, DeviceRevoked.codeFromBody("""{"error" : "device_revoked", "message":"gone"}"""))
        assertNull("no body at all", DeviceRevoked.codeFromBody(null))
        assertNull("an empty body", DeviceRevoked.codeFromBody(""))
        assertNull("a body with no error field", DeviceRevoked.codeFromBody("""{"message":"nope"}"""))
        // Mutant: a substring test on the raw body would pass `device_revoked_other`, which is a different code.
        assertNull(DeviceRevoked.codeFromBody("""{"error":"device_revoked_other"}""").takeIf { it == DeviceRevoked.CODE })
    }

    @Test
    fun `U3 once unlinked nothing polls and nothing re-links`() {
        val policy = UnlinkPolicy()
        policy.onDeviceRevoked(0L)
        assertTrue(policy.shouldPoll())
        policy.onDeviceRevoked(minute)
        assertFalse("no further poll after the unlink", policy.shouldPoll())
        // Mutant: keep enforcing after the unlink, and a deleted family's phone stays locked.
        assertTrue("and the flag stays set", policy.isUnlinked())
        policy.onLinked()
        assertTrue("a later good answer cannot re-link a deleted device", policy.isUnlinked())
    }

    @Test
    fun `U4 a good answer between the two resets the count`() {
        val policy = UnlinkPolicy()
        assertFalse(policy.onDeviceRevoked(0L))
        policy.onLinked()
        assertNull(policy.pendingSinceMs())
        // Mutant: ignore the reset and the next single 401 would confirm on a stale half-answer.
        assertFalse("a fresh first answer again", policy.onDeviceRevoked(minute))
        assertFalse(policy.isUnlinked())
    }
}
