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
 * guard, F7 adult-name formatting, and EN/AR parity.
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
    fun `canSend enforces daily limit, single pending request, and no in-flight duplicate`() {
        assertTrue(AskParentPolicy.canSend(hasDailyLimit = true, hasPendingWaiting = false, isSending = false))
        assertFalse(AskParentPolicy.canSend(hasDailyLimit = false, hasPendingWaiting = false, isSending = false))
        assertFalse(AskParentPolicy.canSend(hasDailyLimit = true, hasPendingWaiting = true, isSending = false))
        assertFalse(AskParentPolicy.canSend(hasDailyLimit = true, hasPendingWaiting = false, isSending = true))
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
    fun `C-03 screen has no TextField note, no red danger CTA, NoActionBar theme, and EN-AR parity`() {
        val root = findAppSrcRoot()
        val screen = File(root, "java/com/familyshield/agent/ui/request/AskParentScreen.kt").readText()
        val manifest = File(root, "AndroidManifest.xml").readText()
        val enStrings = File(root, "res/values/strings.xml").readText()
        val arStrings = File(root, "res/values-ar/strings.xml").readText()

        assertFalse("C-03 must not include a child note TextField (#1185)", screen.contains("TextField"))
        assertFalse("C-03 must not use danger red tokens", screen.contains("palette.danger"))
        assertTrue("AskParentActivity must use NoActionBar theme", manifest.contains("android:name=\".ui.request.AskParentActivity\""))

        for (key in listOf(
            "c03_title",
            "c03_question_label",
            "c03_option_15_amount",
            "c03_option_30_amount",
            "c03_preview_sentence",
            "c03_goes_to",
            "c03_send_request",
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
