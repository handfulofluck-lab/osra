package com.familyshield.agent

import com.familyshield.agent.receivers.AlertThrottlePolicy
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Pure-JVM tests for the shared 1 h Feature #19/#20 throttle: window boundaries, backwards clock,
 * and per-type key independence (accessibility vs vpn alerts never suppress each other).
 */
class AlertThrottlePolicyTest {

    private val now = 1_000_000_000L

    @Test
    fun `never alerted fires`() {
        assertTrue(AlertThrottlePolicy.shouldAlert(null, now))
    }

    @Test
    fun `alert within 1h window is throttled`() {
        val last = now - AlertThrottlePolicy.THROTTLE_WINDOW_MS + 1
        assertFalse(AlertThrottlePolicy.shouldAlert(last, now))
    }

    @Test
    fun `alert exactly at 1h boundary fires again`() {
        val last = now - AlertThrottlePolicy.THROTTLE_WINDOW_MS
        assertTrue(AlertThrottlePolicy.shouldAlert(last, now))
    }

    @Test
    fun `alert after 1h fires again`() {
        val last = now - AlertThrottlePolicy.THROTTLE_WINDOW_MS - 1
        assertTrue(AlertThrottlePolicy.shouldAlert(last, now))
    }

    @Test
    fun `backwards clock stays throttled`() {
        val last = now + 60_000L // clock moved backwards since the last alert
        assertFalse(AlertThrottlePolicy.shouldAlert(last, now))
    }

    @Test
    fun `throttle keys are per type`() {
        assertEquals("tamper_alert_ts_accessibility", AlertThrottlePolicy.throttleKey("accessibility"))
        assertEquals("tamper_alert_ts_vpn", AlertThrottlePolicy.throttleKey("vpn"))
        assertFalse(
            AlertThrottlePolicy.throttleKey("accessibility") == AlertThrottlePolicy.throttleKey("vpn"),
        )
    }

    @Test
    fun `throttle key is prefix plus type`() {
        assertEquals(
            AlertThrottlePolicy.THROTTLE_KEY_PREFIX + "accessibility",
            AlertThrottlePolicy.throttleKey("accessibility"),
        )
    }
}
