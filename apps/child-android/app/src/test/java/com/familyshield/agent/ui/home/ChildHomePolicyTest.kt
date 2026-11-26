package com.familyshield.agent.ui.home

import com.familyshield.agent.network.dto.RoutineDto
import com.familyshield.agent.network.dto.RuleSetDto
import com.familyshield.agent.network.dto.ScreenTimeRuleDto
import java.io.File
import java.time.ZoneOffset
import java.time.ZonedDateTime
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Issue #1179 (C-01 Child home + C-01-RTL): pure JVM tests covering G5 shared time-left ring
 * formula, F7 adults-name formatting (EN + AR), next routine + bedtime, G10 pending-request
 * age-out, calm SOS invariant, feature-switch fallback, and EN/AR string parity.
 */
class ChildHomePolicyTest {

    private val wedAfternoon = ZonedDateTime.of(2026, 11, 25, 15, 18, 0, 0, ZoneOffset.UTC)
    private val satAfternoon = ZonedDateTime.of(2026, 11, 28, 15, 0, 0, 0, ZoneOffset.UTC)

    @Test
    fun `G5 timeBudget uses weekday limit on Wednesday and adds local today bonus`() {
        val rules = RuleSetDto(
            screenTime = ScreenTimeRuleDto(dailyLimitMinutes = 120, weekendLimitMinutes = 180),
        )
        val budget = ChildHomePolicy.timeBudget(
            ruleSet = rules,
            now = wedAfternoon,
            minutesUsedToday = mapOf("a" to 50, "b" to 30),
            localBonusMinutes = 30,
        )
        assertEquals(150, budget.effectiveLimitMinutes)
        assertEquals(80, budget.usedMinutes)
        assertEquals(70, budget.remainingMinutes)
        assertEquals(70f / 150f, budget.remainingFraction, 0.001f)
    }

    @Test
    fun `G5 timeBudget uses weekend limit on Saturday when above zero`() {
        val rules = RuleSetDto(
            screenTime = ScreenTimeRuleDto(dailyLimitMinutes = 120, weekendLimitMinutes = 180),
        )
        val budget = ChildHomePolicy.timeBudget(
            ruleSet = rules,
            now = satAfternoon,
            minutesUsedToday = mapOf("a" to 60),
            localBonusMinutes = 0,
        )
        assertEquals(180, budget.effectiveLimitMinutes)
        assertEquals(120, budget.remainingMinutes)
    }

    @Test
    fun `timeBudget returns null limit when dailyLimitMinutes is zero`() {
        val budget = ChildHomePolicy.timeBudget(
            ruleSet = RuleSetDto(screenTime = ScreenTimeRuleDto(dailyLimitMinutes = 0)),
            now = wedAfternoon,
            minutesUsedToday = mapOf("a" to 25),
            localBonusMinutes = 0,
        )
        assertNull(budget.effectiveLimitMinutes)
        assertNull(budget.remainingMinutes)
        assertEquals(25, budget.usedMinutes)
    }

    @Test
    fun `F7 AdultsNameFormatter follows Arabic Bureau 7191839045 rules for 0, 1, 2, 3, and 4+ adults`() {
        assertEquals("أهلي", AdultsNameFormatter.format(emptyList(), "أهلي", isArabic = true))
        assertEquals("\u2068سارة\u2069", AdultsNameFormatter.format(listOf("سارة"), "أهلي", isArabic = true))
        assertEquals(
            "\u2068سارة\u2069 و\u2068عمر\u2069",
            AdultsNameFormatter.format(listOf("سارة", "عمر"), "أهلي", isArabic = true),
        )
        assertEquals(
            "\u2068سارة\u2069 و\u2068عمر\u2069 و\u2068خالد\u2069",
            AdultsNameFormatter.format(listOf("سارة", "عمر", "خالد"), "أهلي", isArabic = true),
        )
        // Claude lead (#1191 7197409788): 4+ adults fall back to generic form so no adult is silently dropped.
        assertEquals(
            "أهلي",
            AdultsNameFormatter.format(listOf("سارة", "عمر", "خالد", "نور"), "أهلي", isArabic = true),
        )
        assertEquals(
            "my parents",
            AdultsNameFormatter.format(listOf("Sarah", "Omar", "Khaled", "Noor"), "my parents", isArabic = false),
        )
        assertEquals(
            "\u2068Sarah\u2069 and \u2068Omar\u2069",
            AdultsNameFormatter.format(listOf("Sarah", "Omar"), "my parents", isArabic = false),
        )
        assertEquals(
            "\u2068Sarah\u2069, \u2068Omar\u2069 and \u2068Khaled\u2069",
            AdultsNameFormatter.format(listOf("Sarah", "Omar", "Khaled"), "my parents", isArabic = false),
        )
    }

    @Test
    fun `nextRoutine picks soonest upcoming routine today and bedtimeStart hides disabled window`() {
        val rules = RuleSetDto(
            screenTime = ScreenTimeRuleDto(bedtimeStart = "21:30", bedtimeEnd = "07:00"),
            routines = listOf(
                RoutineDto(id = "r1", name = "Dinner", startTime = "18:00", endTime = "19:00", days = listOf(3)),
                RoutineDto(id = "r2", name = "Homework", startTime = "16:00", endTime = "17:00", days = listOf(3)),
            ),
        )
        val next = ChildHomePolicy.nextRoutine(rules, wedAfternoon)
        assertNotNull(next)
        assertEquals("Homework", next!!.name)
        assertEquals("16:00", next.startHhMm)
        assertEquals(42, next.startsInMinutes)
        assertEquals("21:30", ChildHomePolicy.bedtimeStart(rules))

        val disabled = RuleSetDto(screenTime = ScreenTimeRuleDto(bedtimeStart = "00:00", bedtimeEnd = "00:00"))
        assertNull(ChildHomePolicy.bedtimeStart(disabled))
    }

    @Test
    fun `G10 pendingStatus waits under 2 hours and ages out to NO_ANSWER_YET after 2 hours`() {
        val sentAt = 1_000_000L
        val req = PendingChildRequest(requestType = "time", minutes = 15, appLabel = null, sentAtMs = sentAt)
        assertEquals(PendingRequestStatus.WAITING, ChildHomePolicy.pendingStatus(req, sentAt + 60_000L))
        assertEquals(
            PendingRequestStatus.NO_ANSWER_YET,
            ChildHomePolicy.pendingStatus(req, sentAt + ChildHomePolicy.PENDING_AGE_OUT_MS),
        )
        assertEquals(PendingRequestStatus.NONE, ChildHomePolicy.pendingStatus(null, sentAt))
    }

    @Test
    fun `C-01 screen uses calm SOS row, keeps legacy fallback, and has EN-AR parity`() {
        val root = findAppSrcRoot()
        val screen = File(root, "java/com/familyshield/agent/ui/home/ChildHomeScreen.kt").readText()
        val activity = File(root, "java/com/familyshield/agent/setup/PairingActivity.kt").readText()
        val enStrings = File(root, "res/values/strings.xml").readText()
        val arStrings = File(root, "res/values-ar/strings.xml").readText()

        assertFalse("C-01 must never draw a red danger SOS button", screen.contains("palette.danger"))
        assertTrue("PairingActivity must keep C-01 behind ChildUxFlags fallback", activity.contains("ChildUxFlags.c01ChildHomeEnabled"))
        assertTrue("PairingActivity must keep legacy setup/status reachable", activity.contains("forceLegacyStatusView = true"))

        for (key in listOf(
            "c01_tab_today",
            "c01_tab_requests",
            "c01_tab_messages",
            "c01_time_left_today",
            "c01_used_of_limit",
            "c01_ask_more_time",
            "c01_what_adults_see",
            "c01_my_activity",
            "c01_send_sos",
            "c01_call_parent",
            "c01_waiting_reply",
        )) {
            assertTrue("EN strings missing $key", enStrings.contains("name=\"$key\""))
            assertTrue("AR strings missing $key", arStrings.contains("name=\"$key\""))
        }
        // Arabic Bureau 7191839045 + 7197357265 core lines:
        assertTrue(arStrings.contains("يومي"))
        assertTrue(arStrings.contains("الطلبات"))
        assertTrue(arStrings.contains("الرسائل"))
        assertTrue(arStrings.contains("المتبقي اليوم: %1\$s"))
        assertTrue(arStrings.contains("المستخدم: %1\$s · الحد: %2\$s"))
        assertTrue(arStrings.contains("المستخدم اليوم: %1\$s"))
        assertTrue(arStrings.contains("الوقت المتبقي قبل قفل الشاشة: %1\$s"))
        assertTrue(arStrings.contains("التالي: %1\$s %2\$s · الوقت المتبقي: %3\$s"))
        assertTrue(arStrings.contains("الدقائق المتبقية"))
        assertTrue(arStrings.contains("إرسال استغاثة إلى %1\$s"))
        assertTrue(arStrings.contains("الاتصال بأهلي"))
        assertTrue(arStrings.contains("ما الذي يُعرض على %1\$s؟"))
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
