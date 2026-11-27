package com.familyshield.agent.setup

import com.familyshield.agent.network.dto.RuleSetDto
import com.familyshield.agent.network.dto.SchoolHoursDto
import com.familyshield.agent.network.dto.ScreenTimeRuleDto
import com.familyshield.agent.network.dto.WebFilterRuleDto
import com.familyshield.agent.setup.OnboardingPolicy.Grant
import java.util.Locale
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** Plan 1.6: the checklist rules — pairing is complete only when every required grant is in. */
class OnboardingPolicyTest {

    @Test
    fun `required set is the eight Full grants (seven on Play where notification listener is absent)`() {
        val required = Grant.values().filter { it.required }
        assertEquals(
            listOf(
                Grant.ACCESSIBILITY,
                Grant.USAGE_ACCESS,
                Grant.OVERLAY,
                Grant.DEVICE_ADMIN,
                Grant.WEB_FILTER,
                Grant.LOCATION,
                Grant.PRIVATE_DNS,
                Grant.NOTIFICATION_LISTENER,
            ),
            required,
        )
        assertFalse(Grant.BATTERY.required)
        assertTrue(Grant.NOTIFICATION_LISTENER.required)
    }

    @Test
    fun `cannot complete while a required grant is missing, can with only recommended ones missing`() {
        val allButBattery = OnboardingPolicy.rows { it != Grant.BATTERY && it != Grant.USB_DEBUGGING }
        assertTrue(OnboardingPolicy.canComplete(allButBattery))
        assertEquals("All done. Your phone is protected.", OnboardingPolicy.progressLine(allButBattery))

        val noNotificationOnFull = OnboardingPolicy.rows(notificationCaptureAvailable = true) { it != Grant.NOTIFICATION_LISTENER }
        assertFalse(OnboardingPolicy.canComplete(noNotificationOnFull))
        assertEquals(listOf(Grant.NOTIFICATION_LISTENER), OnboardingPolicy.missingRequired(noNotificationOnFull))

        val noOverlay = OnboardingPolicy.rows { it != Grant.OVERLAY }
        assertFalse(OnboardingPolicy.canComplete(noOverlay))
        assertEquals(listOf(Grant.OVERLAY), OnboardingPolicy.missingRequired(noOverlay))
        assertEquals("7 of 8 steps done", OnboardingPolicy.progressLine(noOverlay))

        val nothing = OnboardingPolicy.rows { false }
        assertEquals(8, OnboardingPolicy.missingRequired(nothing).size)
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
        // Full requires notification access (8 grants); Play omits it and stays at 7 required grants.
        assertEquals("0 of 8 steps done", OnboardingPolicy.progressLine(full))
        assertEquals("0 of 7 steps done", OnboardingPolicy.progressLine(play))
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

    @Test
    fun `#1208 - formatWesternInt emits Western ASCII digits even under Arabic-Indic default locale`() {
        val prev = Locale.getDefault()
        try {
            Locale.setDefault(Locale.forLanguageTag("ar-AE-u-nu-arab"))
            val formatted = OnboardingPolicy.formatWesternInt(8)
            assertEquals("8", formatted)
            val arLine = String.format(
                Locale.getDefault(),
                "الخطوات المكتملة: %1\$s من %2\$s",
                OnboardingPolicy.formatWesternInt(0),
                OnboardingPolicy.formatWesternInt(8),
            )
            assertEquals("الخطوات المكتملة: 0 من 8", arLine)
            assertFalse(
                "No Arabic-Indic digits may appear in progress line: $arLine",
                arLine.any { it in '\u0660'..'\u0669' || it in '\u06F0'..'\u06F9' },
            )
        } finally {
            Locale.setDefault(prev)
        }
    }

    @Test
    fun `#1208 B2 - agreementRulesSummary hides when null or empty and lists real family rules when present`() {
        assertNull(OnboardingPolicy.agreementRulesSummary(null))
        assertNull(
            OnboardingPolicy.agreementRulesSummary(
                RuleSetDto(
                    screenTime = ScreenTimeRuleDto(
                        dailyLimitMinutes = 0,
                        bedtimeStart = "",
                        bedtimeEnd = "",
                        schoolHours = SchoolHoursDto(days = emptyList()),
                    ),
                    webFilter = WebFilterRuleDto(blockedCategories = emptyList()),
                ),
            ),
        )

        val populated = OnboardingPolicy.agreementRulesSummary(
            RuleSetDto(
                screenTime = ScreenTimeRuleDto(
                    dailyLimitMinutes = 120,
                    bedtimeStart = "21:00",
                    bedtimeEnd = "07:00",
                    schoolHours = SchoolHoursDto(start = "08:00", end = "14:30", days = listOf(1, 2, 3, 4, 5)),
                ),
                webFilter = WebFilterRuleDto(blockedCategories = listOf("pornography", "gambling", "pornography")),
            ),
        )
        assertNotNull(populated)
        assertEquals(120, populated!!.dailyLimitMinutes)
        assertEquals("21:00", populated.bedtimeStart)
        assertEquals("07:00", populated.bedtimeEnd)
        assertEquals("08:00", populated.schoolStart)
        assertEquals("14:30", populated.schoolEnd)
        assertEquals(listOf("pornography", "gambling"), populated.blockedCategories)
        assertNotNull(OnboardingPolicy.webCategoryLabelRes("pornography"))
        assertNotNull(OnboardingPolicy.webCategoryLabelRes("gambling"))
        assertNull(OnboardingPolicy.webCategoryLabelRes("unknown_category"))
    }
}
