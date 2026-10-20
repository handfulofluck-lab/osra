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
 * Issue #233 review adds the `unlock`/`resume` row: no refusal — the ack names whether the
 * lock/pause screen was up (`detail.screen = dismissed|not_showing`), because the phone showed that
 * a refusal fired exactly when the unlock had worked.
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
    fun `unlock is applied and names the screen it dismissed`() {
        val outcome = EnforceabilityPolicy.unlockOutcome(lockScreenShowing = true)

        assertEquals("ok detail", mapOf("screen" to "dismissed"), (outcome as CommandOutcome.Applied).detail)
    }

    @Test
    fun `an unlock with nothing of ours on screen is still applied, and says so`() {
        // Issue #233 review (F1): refusing here was the bug. With the lock screen up the visible
        // window itself allows the dismiss launch; with nothing up there is nothing to take down and
        // LockState.clear has already dropped the pending lock. A `failed` ack in either case told
        // the parent the child's phone was still covered when it was not.
        val outcome = EnforceabilityPolicy.unlockOutcome(lockScreenShowing = false)

        assertEquals("ok detail", mapOf("screen" to "not_showing"), (outcome as CommandOutcome.Applied).detail)
    }

    @Test
    fun `unlock never names a via path and has no keyguard row`() {
        for (showing in listOf(true, false)) {
            val detail = (EnforceabilityPolicy.unlockOutcome(showing) as CommandOutcome.Applied).detail
            assertEquals("screen for showing=$showing", setOf("screen"), detail.keys)
        }
    }

    @Test
    fun `an unlock ack is ok on the wire, with the screen it found`() {
        val dismissed = CommandAckPolicy.ackFor("c1", EnforceabilityPolicy.unlockOutcome(lockScreenShowing = true))!!
        assertEquals("ok", dismissed.status)
        assertEquals(mapOf("screen" to "dismissed"), dismissed.detail)

        val notShowing = CommandAckPolicy.ackFor("c2", EnforceabilityPolicy.unlockOutcome(lockScreenShowing = false))!!
        assertEquals("ok", notShowing.status)
        assertEquals(mapOf("screen" to "not_showing"), notShowing.detail)
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
