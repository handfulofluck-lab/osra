package com.familyshield.agent.security

import com.familyshield.agent.commands.CommandAckPolicy
import com.familyshield.agent.commands.CommandOutcome
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
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
    fun `lock is applied via the overlay when the service is running and the overlay is granted`() {
        val outcome = EnforceabilityPolicy.lockOutcome(
            canOverlay = true,
            accessibilityRunning = true,
            adminLocked = false,
        )

        assertEquals("overlay", via(outcome))
    }

    /**
     * #389 review: the accessibility service is what makes a lock **hold**. `LockActivity.onPause`
     * deliberately does not re-raise itself, so an overlay-only lock shows once, Home takes it away,
     * and an `ok` would be the same lie as the keyguard-only one this PR removed. Mutant: drop the
     * `!accessibilityRunning` guard from `lockOutcome` and this row, the next one and the admin-only
     * row all go green with `via=overlay`.
     */
    @Test
    fun `an overlay-only lock is refused, because nothing re-raises it after Home`() {
        val outcome = EnforceabilityPolicy.lockOutcome(
            canOverlay = true,
            accessibilityRunning = false,
            adminLocked = false,
        )

        assertEquals("lock_screen_unavailable", refusal(outcome))
    }

    @Test
    fun `an overlay and admin lock is still refused while the service is off`() {
        val outcome = EnforceabilityPolicy.lockOutcome(
            canOverlay = true,
            accessibilityRunning = false,
            adminLocked = true,
        )

        assertEquals("lock_screen_unavailable", refusal(outcome))
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

    /**
     * #368 / ADR-0034: `lockNow()` succeeding is not an applied lock. The screen locks, nothing of ours
     * shows, and the child's own unlock ends it — measured on the Flip4, where the parent was told
     * "locked". Mutant: put `adminLocked ->` back first in `lockOutcome` and this row fails with
     * `via=keyguard`.
     */
    @Test
    fun `a keyguard-only lock is refused, because no OSRA screen can show`() {
        val outcome = EnforceabilityPolicy.lockOutcome(
            canOverlay = false,
            accessibilityRunning = false,
            adminLocked = true,
        )

        assertEquals("lock_screen_unavailable", refusal(outcome))
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
        // #368: the keyguard no longer wins the naming — it cannot show our screen. With the overlay
        // and the service both present the answer is the overlay the dispatcher starts itself.
        assertEquals(
            "overlay",
            via(EnforceabilityPolicy.lockOutcome(canOverlay = true, accessibilityRunning = true, adminLocked = true)),
        )
        assertEquals(
            "accessibility",
            via(EnforceabilityPolicy.lockOutcome(canOverlay = false, accessibilityRunning = true, adminLocked = true)),
        )
    }

    // ---- pause --------------------------------------------------------------------------------

    @Test
    fun `pause is applied via the overlay when the service is running and the overlay is granted`() {
        val outcome = EnforceabilityPolicy.pauseOutcome(canOverlay = true, accessibilityRunning = true)

        assertEquals("overlay", via(outcome))
    }

    /** Same rule as `lock`: with the service off the pause screen is shown once and Home ends it. */
    @Test
    fun `a pause with only the overlay granted is refused`() {
        val outcome = EnforceabilityPolicy.pauseOutcome(canOverlay = true, accessibilityRunning = false)

        assertEquals("lock_screen_unavailable", refusal(outcome))
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
        val outcome = EnforceabilityPolicy.pauseInternetOutcome(webFilterSetUp = false, tunnelRunning = false)

        assertEquals("web_filter_not_set_up", refusal(outcome))
    }

    @Test
    fun `pause_internet is applied only when the sinkhole is actually running`() {
        val outcome = EnforceabilityPolicy.pauseInternetOutcome(webFilterSetUp = true, tunnelRunning = true)

        assertTrue("a running sinkhole is the effect, no detail is needed", outcome is CommandOutcome.Applied)
    }

    // Issue #234: `FilterVpnService.start` returns once the intent is posted, so a consented,
    // prepared filter whose service never came up used to ack `ok` while every packet still passed.
    // Mutant for the row below: `pauseInternetOutcome` returning `Applied` whenever the filter is set
    // up — the row goes red, and with it the claim that the ack describes a running tunnel.
    @Test
    fun `pause_internet is refused when the tunnel never comes up`() {
        val outcome = EnforceabilityPolicy.pauseInternetOutcome(webFilterSetUp = true, tunnelRunning = false)

        assertEquals("web_filter_start_failed", refusal(outcome))
    }

    @Test
    fun `a sinkhole is established only when the service says that mode is up`() {
        // #234 review: the old wait asked whether the service object existed (`onCreate` sets that
        // before `establish()`), so it passed for a service with no fd. These three rows are the
        // semantic boundary; the reset in `stopTunnel` is service wiring, covered by inspection and
        // by the Flip4 rows, not by these (there is no Robolectric in this project to drive it).
        assertTrue(EnforceabilityPolicy.isSinkholeEstablished("sinkhole_all", "sinkhole_all"))
        // Mutant: `tunnelMode != null` → the dns and null rows below stay green only by accident, and
        // a re-mode to dns would ack "paused".
        assertFalse(EnforceabilityPolicy.isSinkholeEstablished("dns", "sinkhole_all"))
        assertFalse("no tunnel at all", EnforceabilityPolicy.isSinkholeEstablished(null, "sinkhole_all"))
    }

    @Test
    fun `awaitFilterRunning does not sleep when the tunnel is already up`() {
        var slept = 0L
        val up = EnforceabilityPolicy.awaitFilterRunning(
            isRunning = { true },
            sleep = { slept += it },
            now = { 0L },
        )

        assertTrue(up)
        assertEquals("the common case must not pay the wait", 0L, slept)
    }

    @Test
    fun `awaitFilterRunning polls until the service reports running`() {
        var clock = 0L
        var polls = 0
        val up = EnforceabilityPolicy.awaitFilterRunning(
            isRunning = { polls++ >= 2 },
            timeoutMs = 400,
            intervalMs = 25,
            sleep = { clock += it },
            now = { clock },
        )

        assertTrue(up)
        assertEquals("two intervals of 25 ms, then the third poll sees it", 50L, clock)
    }

    @Test
    fun `awaitFilterRunning gives up at the deadline instead of blocking the worker`() {
        // Mutant: `while (true)` — the worker stops draining every other command.
        var clock = 0L
        val up = EnforceabilityPolicy.awaitFilterRunning(
            isRunning = { false },
            timeoutMs = 100,
            intervalMs = 25,
            sleep = { clock += it },
            now = { clock },
        )

        assertFalse(up)
        assertEquals(100L, clock)
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

        val internet = CommandAckPolicy.ackFor("c3", EnforceabilityPolicy.pauseInternetOutcome(webFilterSetUp = false, tunnelRunning = false))!!
        assertEquals("failed", internet.status)
        assertEquals(mapOf("reason" to "web_filter_not_set_up"), internet.detail)

        // Issue #234: the second refusal reaches the parent with its own reason, not `not_set_up`.
        val neverUp = CommandAckPolicy.ackFor("c4", EnforceabilityPolicy.pauseInternetOutcome(webFilterSetUp = true, tunnelRunning = false))!!
        assertEquals("failed", neverUp.status)
        assertEquals(mapOf("reason" to "web_filter_start_failed"), neverUp.detail)
    }

    @Test
    fun `an applied lock carries the path the parent can rely on`() {
        val ack = CommandAckPolicy.ackFor(
            "c1",
            EnforceabilityPolicy.lockOutcome(canOverlay = true, accessibilityRunning = true, adminLocked = false),
        )!!

        assertEquals("ok", ack.status)
        assertEquals(mapOf("via" to "overlay"), ack.detail)
    }
}
