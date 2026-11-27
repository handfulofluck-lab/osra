package com.familyshield.agent.ui.request

import java.io.File
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Issue #1179 (C-03 Ask a parent): pure JVM tests covering G2/G3 (whole-day screen time only,
 * 15/30 min only — never 60), #1185 (no child note field), idempotency dedupe key, single-pending
 * & send-failure retry guards, F7 adult-name formatting (incl. 4+ fallback), real launch entry
 * point from C-02 `BlockActivity`, `NoActionBar` manifest theme, LTR numeric isolation, and EN/AR parity.
 */
class AskParentPolicyTest {

    @Test
    fun `only 15 and 30 minutes are allowed and 60 defaults safely to 15`() {
        assertEquals(listOf(15, 30), AskParentPolicy.ALLOWED_MINUTES)
        assertEquals(15, AskParentPolicy.normalizeMinutes(15))
        assertEquals(30, AskParentPolicy.normalizeMinutes(30))
        assertEquals(15, AskParentPolicy.normalizeMinutes(60))
        assertEquals(15, AskParentPolicy.normalizeMinutes(-5))
    }

    @Test
    fun `buildTimeRequest emits exact G2 wire metadata with idempotent dedupe key and no note`() {
        val payload = AskParentPolicy.buildTimeRequest(requestedMinutes = 30, idempotencyToken = "abc-123")
        assertEquals("time", payload.metadata["requestType"])
        assertEquals("30", payload.metadata["minutes"])
        assertEquals("daily_limit", payload.metadata["reason"])
        assertNull("No child note metadata allowed (#1185)", payload.metadata["note"])
        assertNull("No per-app scope in this cut (G3)", payload.metadata["scope"])
        assertEquals("child_time_request:abc-123", payload.dedupeKey)
    }

    @Test
    fun `canSend enforces daily limit, single pending request, and allows retry after send failure`() {
        assertTrue(AskParentPolicy.canSend(hasDailyLimit = true, hasPendingWaiting = false, isSending = false))
        assertFalse(AskParentPolicy.canSend(hasDailyLimit = false, hasPendingWaiting = false, isSending = false))
        assertFalse(AskParentPolicy.canSend(hasDailyLimit = true, hasPendingWaiting = true, isSending = false))
        assertFalse(AskParentPolicy.canSend(hasDailyLimit = true, hasPendingWaiting = false, isSending = true))
        // After a failed POST, hasPendingWaiting stays false and isSending returns to false -> retryable.
        assertEquals(listOf(AskSendState.IDLE, AskSendState.SENDING, AskSendState.SENT, AskSendState.FAILED), AskSendState.values().toList())
    }

    @Test
    fun `formatAdults matches Arabic Bureau 7191839045 rules and uses generic fallback for 4+ adults`() {
        assertEquals("أهلي", AskParentPolicy.formatAdults(emptyList(), "أهلي", isArabic = true))
        assertEquals(
            "\u2068سارة\u2069 و\u2068عمر\u2069",
            AskParentPolicy.formatAdults(listOf("سارة", "عمر"), "أهلي", isArabic = true),
        )
        assertEquals(
            "أهلي",
            AskParentPolicy.formatAdults(listOf("سارة", "عمر", "خالد", "نور"), "أهلي", isArabic = true),
        )
        assertEquals(
            "\u2068Sarah\u2069 and \u2068Omar\u2069",
            AskParentPolicy.formatAdults(listOf("Sarah", "Omar"), "my parents", isArabic = false),
        )
        assertEquals(
            "my parents",
            AskParentPolicy.formatAdults(listOf("Sarah", "Omar", "Khaled", "Noor"), "my parents", isArabic = false),
        )
    }

    @Test
    fun `C-03 wiring pins launch path from BlockActivity, NoActionBar theme, post-success persistence, LTR minutes, and EN-AR parity`() {
        val root = findAppSrcRoot()
        val screen = File(root, "java/com/familyshield/agent/ui/request/AskParentScreen.kt").readText()
        val activity = File(root, "java/com/familyshield/agent/ui/request/AskParentActivity.kt").readText()
        val blockActivity = File(root, "java/com/familyshield/agent/enforcement/BlockActivity.kt").readText()
        val settings = File(root, "java/com/familyshield/agent/data/AgentSettings.kt").readText()
        val manifest = File(root, "AndroidManifest.xml").readText()
        val enStrings = File(root, "res/values/strings.xml").readText()
        val arStrings = File(root, "res/values-ar/strings.xml").readText()

        // No note TextField (#1185) and no red danger CTA.
        assertFalse("C-03 must not include a child note TextField (#1185)", screen.contains("TextField"))
        assertFalse("C-03 must not use danger red tokens", screen.contains("palette.danger"))

        // Finding 1 (K31): C-03 must have a real launch path from C-02 BlockActivity.
        assertTrue(
            "BlockActivity must launch AskParentActivity for daily-limit time requests",
            blockActivity.contains("AskParentActivity.intent("),
        )

        // Finding 5 (K31): assert NoActionBar inside the exact AskParentActivity manifest declaration.
        val askActivityTag = manifest
            .substringAfter("android:name=\".ui.request.AskParentActivity\"")
            .substringBefore("/>")
        assertTrue(
            "AskParentActivity manifest declaration must set Theme.Material.NoActionBar",
            askActivityTag.contains("android:theme=\"@android:style/Theme.Material.NoActionBar\""),
        )

        // Finding 3 (K31): recordPendingRequest runs ONLY inside result.onSuccess, never before POST,
        // and failures transition to AskSendState.FAILED; clearPendingRequest is wired for expiry and unpair.
        val sendFn = activity.substringAfter("private fun sendRequest(").substringBefore("private fun prefs()")
        val onSuccessIdx = sendFn.indexOf(".onSuccess")
        val recordIdx = sendFn.indexOf("recordPendingRequest(")
        val onFailureIdx = sendFn.indexOf(".onFailure")
        assertTrue("recordPendingRequest must run only after result.onSuccess", onSuccessIdx >= 0 && recordIdx > onSuccessIdx && recordIdx < onFailureIdx)
        assertTrue("Failed POST must enter AskSendState.FAILED", sendFn.contains("AskSendState.FAILED"))
        assertTrue("AskParentActivity must expose clearPendingRequest", activity.contains("fun clearPendingRequest("))
        assertTrue("AgentSettings.clearPairing must clear C-03 pending request prefs", settings.contains("AskParentActivity.clearPendingRequest(context)"))

        // Finding 4 (K31): minutes in preview and pending title are wrapped with ltrIsolate.
        assertTrue(activity.contains("AskParentPolicy.ltrIsolate(\"15\")"))
        assertTrue(activity.contains("AskParentPolicy.ltrIsolate(\"30\")"))
        assertTrue(activity.contains("AskParentPolicy.ltrIsolate((pendingMinutes ?: 15).toString())"))

        // UI/UX Bureau #1196 B1 + B2: no native title bar and footer clears system navigation/gesture bar.
        assertTrue(activity.contains("FEATURE_NO_TITLE"))
        assertTrue(screen.contains("navigationBarsPadding()"))

        for (key in listOf(
            "c03_title",
            "c03_question_label",
            "c03_option_15_amount",
            "c03_option_30_amount",
            "c03_preview_sentence",
            "c03_goes_to",
            "c03_send_request",
            "c03_send_failed",
            "c03_waiting_reply",
            "c03_footer_honest",
        )) {
            assertTrue("EN strings missing $key", enStrings.contains("name=\"$key\""))
            assertTrue("AR strings missing $key", arStrings.contains("name=\"$key\""))
        }
        assertTrue(arStrings.contains("أطلب من %1\$s"))
        assertTrue(arStrings.contains("سيصل طلبك إلى %1\$s"))
        assertTrue(arStrings.contains("بانتظار الرد"))
        assertTrue(arStrings.contains("إرسال الطلب"))
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
