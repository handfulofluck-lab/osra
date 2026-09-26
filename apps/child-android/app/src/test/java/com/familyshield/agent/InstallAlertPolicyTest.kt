package com.familyshield.agent

import com.familyshield.agent.receivers.InstallAlertPolicy
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/** Pure-JVM tests for Feature #8 install-approval filtering and the 24 h throttle decision. */
class InstallAlertPolicyTest {

    private val self = "com.familyshield.agent"
    private val now = 1_000_000_000L

    @Test
    fun `fresh install of third party app alerts`() {
        assertTrue(InstallAlertPolicy.shouldAlert("com.example.game", false, self, null, now))
    }

    @Test
    fun `own package is skipped`() {
        assertFalse(InstallAlertPolicy.shouldAlert(self, false, self, null, now))
    }

    @Test
    fun `package replace (update) is skipped`() {
        assertFalse(InstallAlertPolicy.shouldAlert("com.example.game", true, self, null, now))
    }

    @Test
    fun `blank package is skipped`() {
        assertFalse(InstallAlertPolicy.shouldAlert(" ", false, self, null, now))
        assertFalse(InstallAlertPolicy.shouldAlert("", false, self, null, now))
    }

    @Test
    fun `alert within 24h window is throttled`() {
        val last = now - InstallAlertPolicy.THROTTLE_WINDOW_MS + 1
        assertFalse(InstallAlertPolicy.shouldAlert("com.example.game", false, self, last, now))
    }

    @Test
    fun `alert exactly at 24h boundary fires again`() {
        val last = now - InstallAlertPolicy.THROTTLE_WINDOW_MS
        assertTrue(InstallAlertPolicy.shouldAlert("com.example.game", false, self, last, now))
    }

    @Test
    fun `alert after 24h fires again`() {
        val last = now - InstallAlertPolicy.THROTTLE_WINDOW_MS - 1
        assertTrue(InstallAlertPolicy.shouldAlert("com.example.game", false, self, last, now))
    }

    @Test
    fun `backwards clock stays throttled`() {
        val last = now + 60_000L // clock moved backwards since the last alert
        assertFalse(InstallAlertPolicy.shouldAlert("com.example.game", false, self, last, now))
    }

    @Test
    fun `throttle is per package`() {
        val last = now - 1_000L
        assertFalse(InstallAlertPolicy.shouldAlert("com.example.game", false, self, last, now))
        // A different package with no record still alerts.
        assertTrue(InstallAlertPolicy.shouldAlert("com.example.other", false, self, null, now))
    }

    @Test
    fun `throttle key is prefix plus package`() {
        assertEquals(
            "install_alert_ts_com.example.game",
            InstallAlertPolicy.throttleKey("com.example.game"),
        )
        assertEquals(
            InstallAlertPolicy.THROTTLE_KEY_PREFIX + "com.example.game",
            InstallAlertPolicy.throttleKey("com.example.game"),
        )
    }
}
