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
}
