package com.familyshield.agent.enforcement

import com.familyshield.agent.data.WindowKind
import com.familyshield.agent.data.WindowReason
import com.familyshield.agent.network.dto.AppRuleDto
import com.familyshield.agent.network.dto.RoutineDto
import com.familyshield.agent.network.dto.RuleSetDto
import com.familyshield.agent.network.dto.SchoolHoursDto
import com.familyshield.agent.network.dto.ScreenTimeRuleDto
import java.io.File
import java.time.ZoneOffset
import java.time.ZonedDateTime
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Issue #1179 (C-02 Time's up / blocked): pure JVM tests covering exact blocking causes,
 * "later of all active rules" return time, G3 daily-limit-only extra-time ask, G2 request
 * metadata contract (`access` / `time` with `15`/`30` only), calm SOS row, and EN/AR parity.
 */
class BlockExplainPolicyTest {

    private val minecraft = "com.mojang.minecraftpe"
    private val khan = "org.khanacademy.android"
    private val wedAfternoon = ZonedDateTime.of(2026, 11, 25, 16, 0, 0, 0, ZoneOffset.UTC)
    private val wedNight = ZonedDateTime.of(2026, 11, 25, 22, 0, 0, 0, ZoneOffset.UTC)
    private val wedMorning = ZonedDateTime.of(2026, 11, 25, 10, 0, 0, 0, ZoneOffset.UTC)

    @Test
    fun `daily limit reached offers 15 min screen time request and returns after overnight bedtime`() {
        val rules = RuleSetDto(
            screenTime = ScreenTimeRuleDto(
                dailyLimitMinutes = 120,
                bedtimeStart = "21:00",
                bedtimeEnd = "07:00",
            ),
            alwaysAllowedApps = listOf(khan, minecraft, EssentialPackages.OWN_PACKAGE),
        )

        val exp = BlockExplainPolicy.explain(
            ruleSet = rules,
            packageId = minecraft,
            now = wedAfternoon,
            minutesUsedToday = mapOf(minecraft to 120),
            blocklist = emptyMap(),
            pausedInternet = false,
            bonusMinutes = 0,
            fallbackReason = BlockActivity.REASON_TIME_LIMIT,
            fallbackWindow = null,
        )

        assertEquals(BlockCause.DAILY_LIMIT, exp.cause)
        assertEquals(120, exp.usedMinutes)
        assertEquals(120, exp.limitMinutes)
        assertEquals("07:00", exp.backAtTime)
        assertTrue(exp.backAtTomorrow)
        assertTrue("G3: daily limit alone must allow asking for more screen time", exp.canAskForMoreTime)
        assertEquals(listOf(khan), exp.stillOpenPackages)

        val payload = BlockExplainPolicy.buildRequestPayload(minecraft, exp, BlockActivity.REASON_TIME_LIMIT, 15)
        assertEquals("time", payload.metadata["requestType"])
        assertEquals("15", payload.metadata["minutes"])
        assertEquals(minecraft, payload.metadata["packageId"])
        assertEquals("daily_limit", payload.metadata["reason"])
    }

    @Test
    fun `daily limit with bedtime disabled resets at midnight 00_00`() {
        val rules = RuleSetDto(
            screenTime = ScreenTimeRuleDto(
                dailyLimitMinutes = 60,
                bedtimeStart = "00:00",
                bedtimeEnd = "00:00",
            ),
        )
        val exp = BlockExplainPolicy.explain(
            ruleSet = rules,
            packageId = minecraft,
            now = wedAfternoon,
            minutesUsedToday = mapOf(minecraft to 60),
            blocklist = emptyMap(),
            pausedInternet = false,
            bonusMinutes = 0,
            fallbackReason = BlockActivity.REASON_TIME_LIMIT,
            fallbackWindow = null,
        )
        assertEquals(BlockCause.DAILY_LIMIT, exp.cause)
        assertEquals("00:00", exp.backAtTime)
        assertTrue(exp.backAtTomorrow)
        assertTrue(exp.canAskForMoreTime)
    }

    @Test
    fun `per-app time limit does NOT offer whole-day time ask (G3) and sends access request`() {
        val rules = RuleSetDto(
            screenTime = ScreenTimeRuleDto(dailyLimitMinutes = 180, bedtimeStart = "21:00", bedtimeEnd = "07:00"),
            appRules = listOf(AppRuleDto(packageId = minecraft, action = "time_limit", dailyLimitMinutes = 60)),
        )
        val exp = BlockExplainPolicy.explain(
            ruleSet = rules,
            packageId = minecraft,
            now = wedAfternoon,
            minutesUsedToday = mapOf(minecraft to 60),
            blocklist = emptyMap(),
            pausedInternet = false,
            bonusMinutes = 0,
            fallbackReason = BlockActivity.REASON_TIME_LIMIT,
            fallbackWindow = null,
        )

        assertEquals(BlockCause.APP_LIMIT, exp.cause)
        assertEquals(60, exp.usedMinutes)
        assertEquals(60, exp.limitMinutes)
        assertEquals("07:00", exp.backAtTime)
        assertTrue(exp.backAtTomorrow)
        assertFalse("G3: per-app limit must NOT offer daily-limit time ask", exp.canAskForMoreTime)

        val payload = BlockExplainPolicy.buildRequestPayload(minecraft, exp, BlockActivity.REASON_TIME_LIMIT, 15)
        assertEquals("access", payload.metadata["requestType"])
        assertNull(payload.metadata["minutes"])
        assertEquals(minecraft, payload.metadata["packageId"])
    }

    @Test
    fun `overlapping routine and school hours picks the LATER return time`() {
        val rules = RuleSetDto(
            screenTime = ScreenTimeRuleDto(
                bedtimeStart = "21:00",
                bedtimeEnd = "07:00",
                schoolHours = SchoolHoursDto(start = "08:00", end = "15:00", days = listOf(1, 2, 3, 4, 5)),
            ),
            routines = listOf(
                RoutineDto(
                    id = "r1",
                    name = "Morning Study",
                    startTime = "09:00",
                    endTime = "12:30",
                    days = listOf(3),
                    blockedApps = listOf(minecraft),
                ),
            ),
        )
        val exp = BlockExplainPolicy.explain(
            ruleSet = rules,
            packageId = minecraft,
            now = wedMorning,
            minutesUsedToday = emptyMap(),
            blocklist = emptyMap(),
            pausedInternet = false,
            bonusMinutes = 0,
            fallbackReason = BlockActivity.REASON_BLOCKED,
            fallbackWindow = WindowReason(WindowKind.ROUTINE, "Morning Study", "12:30"),
        )

        assertEquals(BlockCause.ROUTINE, exp.cause)
        assertEquals("Morning Study", exp.routineName)
        assertEquals("15:00", exp.backAtTime)
        assertFalse(exp.backAtTomorrow)
        assertFalse(exp.canAskForMoreTime)
    }

    @Test
    fun `explicit block or pause internet never fabricates a return time even during bedtime`() {
        val rules = RuleSetDto(
            screenTime = ScreenTimeRuleDto(bedtimeStart = "21:00", bedtimeEnd = "07:00"),
            appRules = listOf(AppRuleDto(packageId = minecraft, action = "block")),
        )
        val blockedExp = BlockExplainPolicy.explain(
            ruleSet = rules,
            packageId = minecraft,
            now = wedNight,
            minutesUsedToday = emptyMap(),
            blocklist = emptyMap(),
            pausedInternet = false,
            bonusMinutes = 0,
            fallbackReason = BlockActivity.REASON_BLOCKED,
            fallbackWindow = null,
        )
        assertEquals(BlockCause.APP_BLOCKED, blockedExp.cause)
        assertNull(blockedExp.backAtTime)
        assertFalse(blockedExp.canAskForMoreTime)

        val pausedExp = BlockExplainPolicy.explain(
            ruleSet = RuleSetDto(screenTime = ScreenTimeRuleDto(bedtimeStart = "21:00", bedtimeEnd = "07:00")),
            packageId = minecraft,
            now = wedNight,
            minutesUsedToday = emptyMap(),
            blocklist = emptyMap(),
            pausedInternet = true,
            bonusMinutes = 0,
            fallbackReason = BlockActivity.REASON_BLOCKED,
            fallbackWindow = null,
        )
        assertEquals(BlockCause.PAUSED_INTERNET, pausedExp.cause)
        assertNull(pausedExp.backAtTime)
        assertFalse(pausedExp.canAskForMoreTime)
    }

    @Test
    fun `VPN-protected app stays indefinite block even when daily limit is also exhausted`() {
        val rules = RuleSetDto(
            screenTime = ScreenTimeRuleDto(dailyLimitMinutes = 60, bedtimeStart = "21:00", bedtimeEnd = "07:00"),
        )
        val exp = BlockExplainPolicy.explain(
            ruleSet = rules,
            packageId = "com.example.vpn",
            now = wedAfternoon,
            minutesUsedToday = mapOf("com.example.vpn" to 60),
            blocklist = emptyMap(),
            pausedInternet = false,
            bonusMinutes = 0,
            fallbackReason = BlockActivity.REASON_BLOCKED,
            fallbackWindow = null,
            declaresVpnService = true,
        )
        assertEquals(BlockCause.APP_BLOCKED, exp.cause)
        assertNull("VPN-protected app must never promise a return time", exp.backAtTime)
        assertFalse("VPN-protected app must NOT offer a daily-limit screen-time ask", exp.canAskForMoreTime)
    }

    @Test
    fun `overnight bedtime handing off into next-day school hours extends return time to school end`() {
        val rules = RuleSetDto(
            screenTime = ScreenTimeRuleDto(
                bedtimeStart = "21:00",
                bedtimeEnd = "07:00",
                // Thursday (day 4) school hours begin at 06:00, overlapping bedtime end at 07:00.
                schoolHours = SchoolHoursDto(start = "06:00", end = "15:00", days = listOf(1, 2, 3, 4, 5)),
            ),
        )
        val exp = BlockExplainPolicy.explain(
            ruleSet = rules,
            packageId = minecraft,
            now = wedNight,
            minutesUsedToday = emptyMap(),
            blocklist = emptyMap(),
            pausedInternet = false,
            bonusMinutes = 0,
            fallbackReason = BlockActivity.REASON_BLOCKED,
            fallbackWindow = WindowReason(WindowKind.BEDTIME, null, "07:00"),
        )
        assertEquals(BlockCause.BEDTIME, exp.cause)
        assertEquals("15:00", exp.backAtTime)
        assertTrue(exp.backAtTomorrow)
        assertFalse(exp.canAskForMoreTime)
    }

    @Test
    fun `multi-day contiguous chain extending past tomorrow omits Back again card instead of saying Tomorrow`() {
        val rules = RuleSetDto(
            screenTime = ScreenTimeRuleDto(
                bedtimeStart = "21:00",
                bedtimeEnd = "07:00",
                // Thu (4) + Fri (5) school windows 06:00-22:00 chain with daily bedtime 21:00-07:00 until Saturday 07:00.
                schoolHours = SchoolHoursDto(start = "06:00", end = "22:00", days = listOf(4, 5)),
            ),
        )
        val exp = BlockExplainPolicy.explain(
            ruleSet = rules,
            packageId = minecraft,
            now = wedNight,
            minutesUsedToday = emptyMap(),
            blocklist = emptyMap(),
            pausedInternet = false,
            bonusMinutes = 0,
            fallbackReason = BlockActivity.REASON_BLOCKED,
            fallbackWindow = WindowReason(WindowKind.BEDTIME, null, "07:00"),
        )
        assertEquals(BlockCause.BEDTIME, exp.cause)
        assertNull("Return date past tomorrow must be omitted rather than mislabelled Tomorrow", exp.backAtTime)
        assertFalse(exp.backAtTomorrow)
        assertFalse(exp.canAskForMoreTime)
    }

    @Test
    fun `time request only emits 15 or 30 minutes and rejects 60 for this cut`() {
        val exp = BlockExplanation(cause = BlockCause.DAILY_LIMIT, canAskForMoreTime = true)
        assertEquals("15", BlockExplainPolicy.buildRequestPayload(minecraft, exp, "time_limit", 15).metadata["minutes"])
        assertEquals("30", BlockExplainPolicy.buildRequestPayload(minecraft, exp, "time_limit", 30).metadata["minutes"])
        assertEquals("15", BlockExplainPolicy.buildRequestPayload(minecraft, exp, "time_limit", 60).metadata["minutes"])
    }

    @Test
    fun `isolation helpers wrap with LRI, non-breaking single-unit LTR ranges, and FSI markers`() {
        assertEquals("\u2066Minecraft\u2069", BlockExplainPolicy.ltrIsolate(" Minecraft "))
        assertEquals("\u206621:00\u00A0\u2060–\u2060\u00A007:00\u2069", BlockExplainPolicy.ltrRange(" 21:00 ", " 07:00 "))
        assertEquals("\u2068Homework\u2069", BlockExplainPolicy.firstStrongIsolate(" Homework "))
    }

    @Test
    fun `C-02 screen keeps calm SOS row, NoActionBar manifest theme, feature switch fallback, and EN-AR string parity`() {
        val root = findAppSrcRoot()
        val manifest = File(root, "AndroidManifest.xml").readText()
        val screen = File(root, "java/com/familyshield/agent/ui/block/BlockedAppScreen.kt").readText()
        val activity = File(root, "java/com/familyshield/agent/enforcement/BlockActivity.kt").readText()
        val enStrings = File(root, "res/values/strings.xml").readText()
        val arStrings = File(root, "res/values-ar/strings.xml").readText()

        val blockActivityTag = manifest.substringAfter("android:name=\".enforcement.BlockActivity\"").substringBefore("/>")
        assertTrue(
            "BlockActivity must use Theme.Material.NoActionBar so no grey native title bar renders above C-02",
            blockActivityTag.contains("android:theme=\"@android:style/Theme.Material.NoActionBar\""),
        )
        assertTrue("BlockActivity must isolate time ranges as one LTR unit", activity.contains("BlockExplainPolicy.ltrRange("))
        assertFalse("C-02 must never draw a red danger SOS button", screen.contains("palette.danger"))
        assertTrue("BlockActivity must keep C-02 behind ChildUxFlags fallback", activity.contains("ChildUxFlags.c02BlockedScreenEnabled"))
        assertTrue("BlockActivity must wire SosActivity for calm SOS row", activity.contains("SosActivity::class.java"))

        for (key in listOf(
            "c02_paused_title",
            "c02_reason_daily_limit",
            "c02_reason_bedtime",
            "c02_reason_school",
            "c02_back_again_label",
            "c02_back_at_today",
            "c02_back_at_tomorrow",
            "c02_still_open_label",
            "c02_ask_more_time_15",
            "c02_ask_to_open",
            "c02_waiting_reply",
            "c02_call_parent",
            "c02_see_my_rules",
            "c02_send_sos_row",
            "c02_emergency_note",
        )) {
            assertTrue("EN strings missing $key", enStrings.contains("name=\"$key\""))
            assertTrue("AR strings missing $key", arStrings.contains("name=\"$key\""))
        }
        // Arabic Bureau 7191839045 + 7204732398 core lines:
        assertTrue(arStrings.contains("%1\$s متوقف مؤقتًا"))
        assertTrue(arStrings.contains("المستخدم: %1\$s · الحد: %2\$s"))
        assertTrue(arStrings.contains("وقت الشاشة اليومي: المستخدم %1\$s، والحد %2\$s"))
        assertTrue(arStrings.contains("جدول «%1\$s» سارٍ الآن."))
        assertTrue(arStrings.contains("ما زال متاحًا لك"))
        assertTrue(arStrings.contains("إرسال استغاثة إلى أهلي"))
        assertTrue(arStrings.contains("الاتصال بأهلي"))
        assertTrue(arStrings.contains("عرض قواعدي"))
    }

    private fun findAppSrcRoot(): File {
        var dir = File(System.getProperty("user.dir") ?: ".")
        repeat(5) {
            val candidate = File(dir, "src/main")
            if (candidate.isDirectory) return candidate
            val nested = File(dir, "app/src/main")
            if (nested.isDirectory) return nested
            dir = dir.parentFile ?: return candidate
        }
        return File("src/main")
    }
}
