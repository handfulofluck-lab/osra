package com.familyshield.agent.security

import com.familyshield.agent.commands.CommandAckPolicy
import com.familyshield.agent.commands.CommandOutcome
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Issue #231 review, D1: on a Flip4 with overlay off, accessibility off and no device admin, `lock`
 * acked `ok` while the OS logged `Background activity launch blocked! … LockActivity` and the
 * launcher stayed in front. D2: `pause_internet` acked with no VPN consented and `ping 8.8.8.8`
 * still answered. [EnforceabilityPolicy] is the pure rule that decides whether any path can make the
 * effect observable; these tests pin every row of both tables plus the ack the reason becomes.
 * Issue #233 adds the `unlock`/`resume` table: the same two paths, a refusal of its own, and no
 * keyguard row.
 */
class EnforceabilityPolicyTest {

    /** The `detail.via` of an [CommandOutcome.Applied], with the actual outcome in the failure. */
    private fun via(outcome: CommandOutcome): String {
        assertTrue("expected Applied with detail.via, got $outcome", outcome is CommandOutcome.Applied)
        return (outcome as CommandOutcome.Applied).detail["via"]
            ?: throw AssertionError("expected detail.via, got $outcome")
    }

    private fun refusal(outcome: CommandOutcome): String {
        assertTrue("expected Refused, got $outcome", outcome is CommandOutcome.Refused)
        return (outcome as CommandOutcome.Refused).reason
    }

    // ---- lock ---------------------------------------------------------------------------------

    @Test
    fun `lock is applied via the overlay when the overlay permission is granted`() {
        val outcome = EnforceabilityPolicy.lockOutcome(
            canOverlay = true,
            accessibilityRunning = false,
            adminLocked = false,
        )

        assertEquals("overlay", via(outcome))
    }

    @Test
    fun `lock is applied via accessibility when the service is bound and the overlay is off`() {
        val outcome = EnforceabilityPolicy.lockOutcome(
            canOverlay = false,
            accessibilityRunning = true,
            adminLocked = false,
        )

        assertEquals("accessibility", via(outcome))
    }

    @Test
    fun `lock is applied via the keyguard when lockNow succeeded`() {
        val outcome = EnforceabilityPolicy.lockOutcome(
            canOverlay = false,
            accessibilityRunning = false,
            adminLocked = true,
        )

        assertEquals("keyguard", via(outcome))
    }

    @Test
    fun `lock is refused when no path can lock`() {
        val outcome = EnforceabilityPolicy.lockOutcome(
            canOverlay = false,
            accessibilityRunning = false,
            adminLocked = false,
        )

        assertEquals("lock_screen_unavailable", refusal(outcome))
    }

    @Test
    fun `lock names the strongest available path when several can lock`() {
        assertEquals(
            "keyguard",
            via(EnforceabilityPolicy.lockOutcome(canOverlay = true, accessibilityRunning = true, adminLocked = true)),
        )
        assertEquals(
            "overlay",
            via(EnforceabilityPolicy.lockOutcome(canOverlay = true, accessibilityRunning = true, adminLocked = false)),
        )
    }

    // ---- pause --------------------------------------------------------------------------------

    @Test
    fun `pause is applied via the overlay when the overlay permission is granted`() {
        val outcome = EnforceabilityPolicy.pauseOutcome(canOverlay = true, accessibilityRunning = false)

        assertEquals("overlay", via(outcome))
    }

    @Test
    fun `pause is applied via accessibility when the service is bound and the overlay is off`() {
        val outcome = EnforceabilityPolicy.pauseOutcome(canOverlay = false, accessibilityRunning = true)

        assertEquals("accessibility", via(outcome))
    }

    @Test
    fun `pause is refused when neither the overlay nor accessibility can show it`() {
        val outcome = EnforceabilityPolicy.pauseOutcome(canOverlay = false, accessibilityRunning = false)

        assertEquals("lock_screen_unavailable", refusal(outcome))
    }

    @Test
    fun `pause prefers the overlay over the event-driven re-raise`() {
        assertEquals(
            "overlay",
            via(EnforceabilityPolicy.pauseOutcome(canOverlay = true, accessibilityRunning = true)),
        )
    }

    // ---- unlock -------------------------------------------------------------------------------

    @Test
    fun `unlock is applied via the overlay when the overlay permission is granted`() {
        val outcome = EnforceabilityPolicy.unlockOutcome(canOverlay = true, accessibilityRunning = false)

        assertEquals("overlay", via(outcome))
    }

    @Test
    fun `unlock is applied via accessibility when the service is bound and the overlay is off`() {
        val outcome = EnforceabilityPolicy.unlockOutcome(canOverlay = false, accessibilityRunning = true)

        assertEquals("accessibility", via(outcome))
    }

    @Test
    fun `unlock is refused when neither the overlay nor accessibility can dismiss it`() {
        val outcome = EnforceabilityPolicy.unlockOutcome(canOverlay = false, accessibilityRunning = false)

        assertEquals("unlock_screen_unavailable", refusal(outcome))
    }

    @Test
    fun `unlock prefers the overlay and never names a keyguard path`() {
        assertEquals(
            "overlay",
            via(EnforceabilityPolicy.unlockOutcome(canOverlay = true, accessibilityRunning = true)),
        )
    }

    // ---- pause_internet -----------------------------------------------------------------------

    @Test
    fun `pause_internet is refused when no web filter is set up`() {
        val outcome = EnforceabilityPolicy.pauseInternetOutcome(webFilterSetUp = false)

        assertEquals("web_filter_not_set_up", refusal(outcome))
    }

    @Test
    fun `pause_internet is applied when the web filter is set up`() {
        val outcome = EnforceabilityPolicy.pauseInternetOutcome(webFilterSetUp = true)

        assertTrue("a running sinkhole is the effect, no detail is needed", outcome is CommandOutcome.Applied)
    }

    // ---- the reason reaches the wire ----------------------------------------------------------

    @Test
    fun `the D1 and D2 refusals become failed acks with their reason in detail`() {
        val lock = CommandAckPolicy.ackFor(
            "c1",
            EnforceabilityPolicy.lockOutcome(canOverlay = false, accessibilityRunning = false, adminLocked = false),
        )!!
        assertEquals("failed", lock.status)
        assertEquals(mapOf("reason" to "lock_screen_unavailable"), lock.detail)

        val pause = CommandAckPolicy.ackFor("c2", EnforceabilityPolicy.pauseOutcome(false, false))!!
        assertEquals("failed", pause.status)
        assertEquals(mapOf("reason" to "lock_screen_unavailable"), pause.detail)

        val internet = CommandAckPolicy.ackFor("c3", EnforceabilityPolicy.pauseInternetOutcome(false))!!
        assertEquals("failed", internet.status)
        assertEquals(mapOf("reason" to "web_filter_not_set_up"), internet.detail)

        val unlock = CommandAckPolicy.ackFor("c4", EnforceabilityPolicy.unlockOutcome(false, false))!!
        assertEquals("failed", unlock.status)
        assertEquals(mapOf("reason" to "unlock_screen_unavailable"), unlock.detail)
    }

    @Test
    fun `an applied lock carries the path the parent can rely on`() {
        val ack = CommandAckPolicy.ackFor(
            "c1",
            EnforceabilityPolicy.lockOutcome(canOverlay = true, accessibilityRunning = false, adminLocked = false),
        )!!

        assertEquals("ok", ack.status)
        assertEquals(mapOf("via" to "overlay"), ack.detail)
    }
}
