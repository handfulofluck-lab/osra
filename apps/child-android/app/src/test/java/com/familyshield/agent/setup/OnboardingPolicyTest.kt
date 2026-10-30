package com.familyshield.agent.setup

import com.familyshield.agent.setup.OnboardingPolicy.Grant
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** Plan 1.6: the checklist rules — pairing is complete only when every required grant is in. */
class OnboardingPolicyTest {

    @Test
    fun `required set is the seven the product does not work without`() {
        val required = Grant.values().filter { it.required }
        assertEquals(
            listOf(Grant.ACCESSIBILITY, Grant.USAGE_ACCESS, Grant.OVERLAY, Grant.DEVICE_ADMIN, Grant.WEB_FILTER, Grant.LOCATION, Grant.PRIVATE_DNS),
            required,
        )
        assertFalse(Grant.BATTERY.required)
        assertFalse(Grant.NOTIFICATION_LISTENER.required)
    }

    @Test
    fun `cannot complete while a required grant is missing, can with only recommended ones missing`() {
        val allButBattery = OnboardingPolicy.rows { it != Grant.BATTERY && it != Grant.NOTIFICATION_LISTENER }
        assertTrue(OnboardingPolicy.canComplete(allButBattery))
        assertEquals("7 of 7 required grants done — protection is complete", OnboardingPolicy.progressLine(allButBattery))

        val noOverlay = OnboardingPolicy.rows { it != Grant.OVERLAY }
        assertFalse(OnboardingPolicy.canComplete(noOverlay))
        assertEquals(listOf(Grant.OVERLAY), OnboardingPolicy.missingRequired(noOverlay))
        assertEquals("6 of 7 required grants done", OnboardingPolicy.progressLine(noOverlay))

        val nothing = OnboardingPolicy.rows { false }
        assertEquals(7, OnboardingPolicy.missingRequired(nothing).size)
    }

    @Test
    fun `rows keep the grant order so the parent does the cheapest and most important first`() {
        val rows = OnboardingPolicy.rows { true }
        assertEquals(Grant.values().toList(), rows.map { it.grant })
    }

    @Test
    fun `oem hints exist where the OEM hides a switch, not elsewhere`() {
        assertNotNull(OnboardingPolicy.oemHint(Grant.BATTERY, "samsung"))
        assertNotNull(OnboardingPolicy.oemHint(Grant.ACCESSIBILITY, "Samsung"))
        assertNotNull(OnboardingPolicy.oemHint(Grant.BATTERY, "Xiaomi"))
        assertNotNull(OnboardingPolicy.oemHint(Grant.OVERLAY, "xiaomi"))
        assertNotNull(OnboardingPolicy.oemHint(Grant.BATTERY, "HUAWEI"))
        assertNull(OnboardingPolicy.oemHint(Grant.OVERLAY, "samsung"))
        assertNull(OnboardingPolicy.oemHint(Grant.BATTERY, "Google"))
        assertNull(OnboardingPolicy.oemHint(Grant.BATTERY, null))
    }

    @Test
    fun `private dns is fine unless a provider hostname is set`() {
        assertTrue(OnboardingPolicy.privateDnsOk(null))
        assertTrue(OnboardingPolicy.privateDnsOk("off"))
        assertTrue(OnboardingPolicy.privateDnsOk("opportunistic"))
        assertFalse(OnboardingPolicy.privateDnsOk("hostname"))
        assertFalse(OnboardingPolicy.privateDnsOk(" HOSTNAME "))
    }

    /**
     * ADR-0016 §4: the Play artefact has no NotificationListenerService, so it must not ask for a
     * permission it cannot use — a store reviewer sees the request even when the code no-ops.
     */
    @Test
    fun `the notification row exists only in a build that can capture notifications`() {
        val full = OnboardingPolicy.rows(notificationCaptureAvailable = true) { false }
        val play = OnboardingPolicy.rows(notificationCaptureAvailable = false) { false }
        assertTrue(full.any { it.grant == OnboardingPolicy.Grant.NOTIFICATION_LISTENER })
        assertFalse(play.any { it.grant == OnboardingPolicy.Grant.NOTIFICATION_LISTENER })
        // The row is recommended, not required: the progress line and the completion rule are identical.
        assertEquals(OnboardingPolicy.progressLine(full), OnboardingPolicy.progressLine(play))
        val playAllGranted = OnboardingPolicy.rows(notificationCaptureAvailable = false) { true }
        assertTrue(OnboardingPolicy.canComplete(playAllGranted))
        assertTrue(OnboardingPolicy.canComplete(OnboardingPolicy.rows(notificationCaptureAvailable = true) { true }))
    }

    /** ADR-0021 B3: a build that cannot capture something says so, next to the grants. */
    @Test
    fun `the capture notice names exactly what this build cannot do`() {
        assertNull(OnboardingPolicy.captureNotice(notificationCaptureAvailable = true, callSmsCaptureAvailable = true))
        val play = OnboardingPolicy.captureNotice(notificationCaptureAvailable = false, callSmsCaptureAvailable = false)
        assertNotNull(play)
        assertTrue(play!!.contains("notification"))
        assertTrue(play.contains("call and SMS"))
        val listenerOnly = OnboardingPolicy.captureNotice(notificationCaptureAvailable = false, callSmsCaptureAvailable = true)
        assertTrue(listenerOnly!!.contains("notification"))
        assertFalse(listenerOnly.contains("call and SMS"))
    }

    @Test
    fun `#81 - USB debugging off is recommended, not required, and listed after battery`() {
        assertFalse(Grant.USB_DEBUGGING.required)
        val order = OnboardingPolicy.rows { true }.map { it.grant }
        assertEquals(order.indexOf(Grant.BATTERY) + 1, order.indexOf(Grant.USB_DEBUGGING))
        assertTrue("a missing USB row never blocks completion", OnboardingPolicy.canComplete(OnboardingPolicy.rows { it != Grant.USB_DEBUGGING }))
    }

    @Test
    fun `#81 - ADB_ENABLED 1 means USB debugging is on, 0 or unreadable means off`() {
        assertFalse(OnboardingPolicy.usbDebuggingOff(1))
        assertTrue(OnboardingPolicy.usbDebuggingOff(0))
        assertTrue(OnboardingPolicy.usbDebuggingOff(null))
    }
}
