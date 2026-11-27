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
    fun `G5 B1 bonusMinutesForToday sums only today bonus_time grants and ignores yesterday and ruleSet aggregate`() {
        val yesterdayMs = wedAfternoon.minusDays(1).toInstant().toEpochMilli()
        val todayMorningMs = wedAfternoon.minusHours(3).toInstant().toEpochMilli()
        val todayEarlierMs = wedAfternoon.minusMinutes(20).toInstant().toEpochMilli()
        val decisions = listOf(
            ChildDecisionRecord(kind = "bonus_time", minutes = 45, timestampMs = yesterdayMs),
            ChildDecisionRecord(kind = "bonus_time", minutes = 15, timestampMs = todayMorningMs),
            ChildDecisionRecord(kind = "bonus_time", minutes = 30, timestampMs = todayEarlierMs),
            ChildDecisionRecord(kind = "rules_updated", minutes = 60, timestampMs = todayEarlierMs),
            ChildDecisionRecord(kind = "bonus_time", minutes = -10, timestampMs = todayEarlierMs),
        )
        assertEquals(45, ChildHomePolicy.bonusMinutesForToday(decisions, wedAfternoon))
        // Even if ruleSet carries a stale/unrelated aggregate, timeBudget uses only local today grants.
        val rules = RuleSetDto(
            screenTime = ScreenTimeRuleDto(dailyLimitMinutes = 120, weekendLimitMinutes = 180),
        )
        val nextDay = wedAfternoon.plusDays(1)
        assertEquals(0, ChildHomePolicy.bonusMinutesForToday(decisions, nextDay))
        val nextDayBudget = ChildHomePolicy.timeBudget(
            ruleSet = rules,
            now = nextDay,
            minutesUsedToday = mapOf("a" to 20),
            localBonusMinutes = ChildHomePolicy.bonusMinutesForToday(decisions, nextDay),
        )
        assertEquals(120, nextDayBudget.effectiveLimitMinutes)
        assertEquals(100, nextDayBudget.remainingMinutes)
    }

    @Test
    fun `B2 submitTimeRequest persists pending only on POST success and never latches on failure`() {
        val saved = mutableListOf<PendingChildRequest>()
        val failed = kotlinx.coroutines.runBlocking {
            ChildHomePolicy.submitTimeRequest(
                minutes = 30,
                nowMs = 1_700_000_000_000L,
                postRequest = { Result.failure(java.io.IOException("offline")) },
                persistPending = { saved += it },
            )
        }
        assertFalse("failed POST must return false", failed)
        assertTrue("failed POST must NEVER save PendingChildRequest", saved.isEmpty())

        val succeeded = kotlinx.coroutines.runBlocking {
            ChildHomePolicy.submitTimeRequest(
                minutes = 30,
                nowMs = 1_700_000_000_000L,
                postRequest = { Result.success(Unit) },
                persistPending = { saved += it },
            )
        }
        assertTrue("successful POST must return true", succeeded)
        assertEquals(1, saved.size)
        assertEquals("time", saved[0].requestType)
        assertEquals(30, saved[0].minutes)
        assertEquals(1_700_000_000_000L, saved[0].sentAtMs)
    }

    @Test
    fun `C-01 screen uses calm SOS row, keeps legacy fallback, and has EN-AR parity`() {
        val root = findAppSrcRoot()
        val screen = File(root, "java/com/familyshield/agent/ui/home/ChildHomeScreen.kt").readText()
        val activity = File(root, "java/com/familyshield/agent/setup/PairingActivity.kt").readText()
        val enStrings = File(root, "res/values/strings.xml").readText()
        val arStrings = File(root, "res/values-ar/strings.xml").readText()

        val activityCode = activity.lineSequence()
            .filterNot { it.trimStart().startsWith("//") || it.trimStart().startsWith("*") }
            .joinToString("\n")
        assertFalse("C-01 must never draw a red danger SOS button", screen.contains("palette.danger"))
        assertFalse("B1: PairingActivity must never call bonusMinutesTodaySnapshot", activityCode.contains("bonusMinutesTodaySnapshot"))
        assertFalse("B1: PairingActivity code must never read bonusMinutesToday", activityCode.contains("bonusMinutesToday"))
        assertTrue("B1: PairingActivity must sum today bonus from decisions", activityCode.contains("ChildHomePolicy.bonusMinutesForToday("))
        assertTrue("B2: PairingActivity must route time requests through submitTimeRequest", activityCode.contains("ChildHomePolicy.submitTimeRequest("))
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
            "c01_request_failed",
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
        assertTrue(arStrings.contains("بالدقائق"))
        assertFalse(arStrings.contains("الدقائق المتبقية"))
        assertTrue(arStrings.contains("إرسال استغاثة إلى %1\$s"))
        assertTrue(arStrings.contains("الاتصال بأهلي"))
        assertTrue(arStrings.contains("ما الذي يُعرض على %1\$s؟"))
        assertTrue(screen.contains("ChildHomePolicy.shouldShowRingCaption(fontScale)"))
    }

    @Test
    fun `Arabic C-01 minutes, hours, pending, and bonus strings format with Western digits only and ring caption hides above 1_3x`() {
        // Mutant A: keep `%1$d` in `c01_minutes` / `c01_hours` / `c01_pending_time_title` / `c01_decision_bonus_*`
        // or format integers under the active Arabic locale -> Arabic-Indic digits (`٤٢`, `٧٨`, `١٢٠`, `١٥`) appear.
        // Mutant B: render `c01_ring_unit_min` unconditionally at 2.0x text scale -> caption collides inside the 96 dp ring.
        val root = findAppSrcRoot()
        val enDoc = javax.xml.parsers.DocumentBuilderFactory.newInstance().newDocumentBuilder()
            .parse(File(root, "res/values/strings.xml"))
        val arDoc = javax.xml.parsers.DocumentBuilderFactory.newInstance().newDocumentBuilder()
            .parse(File(root, "res/values-ar/strings.xml"))
        val activityCode = File(root, "java/com/familyshield/agent/setup/PairingActivity.kt")
            .readText()
            .lineSequence()
            .filterNot { it.trimStart().startsWith("//") || it.trimStart().startsWith("*") }
            .joinToString("\n")

        fun collectC01Strings(doc: org.w3c.dom.Document): Map<String, String> {
            val out = LinkedHashMap<String, String>()
            val nodes = doc.getElementsByTagName("string")
            for (i in 0 until nodes.length) {
                val el = nodes.item(i) as org.w3c.dom.Element
                val name = el.getAttribute("name")
                if (name.startsWith("c01_")) out[name] = el.textContent
            }
            return out
        }

        fun collectC01Plurals(doc: org.w3c.dom.Document): Map<String, Map<String, String>> {
            val out = LinkedHashMap<String, Map<String, String>>()
            val nodes = doc.getElementsByTagName("plurals")
            for (i in 0 until nodes.length) {
                val el = nodes.item(i) as org.w3c.dom.Element
                val name = el.getAttribute("name")
                if (!name.startsWith("c01_")) continue
                val items = LinkedHashMap<String, String>()
                val itemNodes = el.getElementsByTagName("item")
                for (j in 0 until itemNodes.length) {
                    val item = itemNodes.item(j) as org.w3c.dom.Element
                    items[item.getAttribute("quantity")] = item.textContent
                }
                out[name] = items
            }
            return out
        }

        val enStrings = collectC01Strings(enDoc)
        val arStrings = collectC01Strings(arDoc)
        val enPlurals = collectC01Plurals(enDoc)
        val arPlurals = collectC01Plurals(arDoc)

        val intPlaceholder = Regex("%(\\d+\\$)?d")
        for ((k, v) in enStrings + arStrings) {
            assertFalse("c01 string $k must use %s with formatWesternInt, never %d: $v", intPlaceholder.containsMatchIn(v))
        }
        for ((k, map) in enPlurals + arPlurals) {
            for ((qty, v) in map) {
                assertFalse("c01 plural $k[$qty] must use %s with formatWesternInt, never %d: $v", intPlaceholder.containsMatchIn(v))
            }
        }

        assertEquals("بالدقائق", arStrings["c01_ring_unit_min"])

        // Format under an Arabic locale that uses Arabic-Indic digits for `%d`, proving Western digits win.
        val arIndicLocale = java.util.Locale.forLanguageTag("ar-AE-u-nu-arab")
        val nonWesternDigits = Regex("[\\u0660-\\u0669\\u06F0-\\u06F9]")
        val defaultBefore = java.util.Locale.getDefault()
        try {
            java.util.Locale.setDefault(arIndicLocale)
            assertEquals("42", ChildHomePolicy.formatWesternInt(42))

            val arMinutes = arPlurals.getValue("c01_minutes")
            for ((qty, sample) in listOf("zero" to 0, "one" to 1, "two" to 2, "few" to 5, "many" to 42, "other" to 120)) {
                val formatted = String.format(arIndicLocale, arMinutes.getValue(qty), ChildHomePolicy.formatWesternInt(sample))
                assertFalse("Arabic minutes [$qty=$sample] must contain no Arabic-Indic digits: $formatted", nonWesternDigits.containsMatchIn(formatted))
            }
            assertEquals("42 دقيقة", String.format(arIndicLocale, arMinutes.getValue("many"), ChildHomePolicy.formatWesternInt(42)))
            assertEquals("120 دقيقة", String.format(arIndicLocale, arMinutes.getValue("other"), ChildHomePolicy.formatWesternInt(120)))

            val arHours = arPlurals.getValue("c01_hours")
            for ((qty, sample) in listOf("zero" to 0, "one" to 1, "two" to 2, "few" to 4, "many" to 12, "other" to 100)) {
                val formatted = String.format(arIndicLocale, arHours.getValue(qty), ChildHomePolicy.formatWesternInt(sample))
                assertFalse("Arabic hours [$qty=$sample] must contain no Arabic-Indic digits: $formatted", nonWesternDigits.containsMatchIn(formatted))
            }

            val pendingFormatted = String.format(
                arIndicLocale,
                arStrings.getValue("c01_pending_time_title"),
                ChildHomePolicy.formatWesternInt(15),
            )
            assertEquals("طلبك: 15 دقيقة إضافية من وقت الشاشة", pendingFormatted)
            assertFalse(nonWesternDigits.containsMatchIn(pendingFormatted))

            val bonusNamed = String.format(
                arIndicLocale,
                arStrings.getValue("c01_decision_bonus_named"),
                ChildHomePolicy.formatWesternInt(30),
                "سارة",
            )
            assertEquals("30 دقيقة إضافية من سارة", bonusNamed)
            assertFalse(nonWesternDigits.containsMatchIn(bonusNamed))

            val bonusUnnamed = String.format(
                arIndicLocale,
                arStrings.getValue("c01_decision_bonus_unnamed"),
                ChildHomePolicy.formatWesternInt(15),
            )
            assertEquals("15 دقيقة إضافية من وقت الشاشة", bonusUnnamed)
            assertFalse(nonWesternDigits.containsMatchIn(bonusUnnamed))
        } finally {
            java.util.Locale.setDefault(defaultBefore)
        }

        // PairingActivity wiring checks for Western-digit formatting at all 5 call sites:
        assertTrue(activityCode.contains("resources.getQuantityString(R.plurals.c01_hours, hours, hoursWestern)"))
        assertTrue(activityCode.contains("resources.getQuantityString(R.plurals.c01_minutes, mins, minsWestern)"))
        assertTrue(activityCode.contains("R.string.c01_pending_time_title,\n                com.familyshield.agent.ui.home.ChildHomePolicy.formatWesternInt("))
        assertTrue(activityCode.contains("R.string.c01_decision_bonus_named,\n                            minsWestern,"))
        assertTrue(activityCode.contains("getString(R.string.c01_decision_bonus_unnamed, minsWestern)"))

        // Ring caption visibility threshold (~1.3x text scale):
        assertTrue(ChildHomePolicy.shouldShowRingCaption(1.0f))
        assertTrue(ChildHomePolicy.shouldShowRingCaption(1.3f))
        assertFalse(ChildHomePolicy.shouldShowRingCaption(1.31f))
        assertFalse(ChildHomePolicy.shouldShowRingCaption(2.0f))
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
