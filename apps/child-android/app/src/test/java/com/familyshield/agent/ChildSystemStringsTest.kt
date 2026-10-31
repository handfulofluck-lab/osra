package com.familyshield.agent

import java.io.File
import javax.xml.parsers.DocumentBuilderFactory
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import org.w3c.dom.Element

/**
 * #480: the lines Android itself shows for the agent (the Accessibility list, the device-admin sheet)
 * and the wipe notice on the pairing screen speak Arabic, exactly as Karim approved on 2026-10-31 06:20Z
 * (`arabic-review/2026-10-31-child-system-strings`, Q1–Q5; the block screen's window line, Q10, 15:30Z). Each line is pinned as a literal, so a
 * changed or missing translation turns this red.
 *
 * `app_name`, `app_name_ar` and `sos_tile_label` are brand names: they keep no Arabic override on
 * purpose, and the last row holds that.
 *
 * As in `PairingStringsTest`, the resource merger is not on the JVM test classpath, so this reads the
 * two source files. How the sheets render on a phone needs a device.
 */
class ChildSystemStringsTest {

    private val english = strings("values/strings.xml")
    private val arabic = strings("values-ar/strings.xml")

    /** Karim's approved Arabic, line for line. */
    private val approvedArabic = linkedMapOf(
        "accessibility_service_label" to "إمكانية الوصول في OSRA",
        "accessibility_description" to "يراقب OSRA استخدام التطبيقات لتطبيق قواعد وقت الشاشة التي وضعها والدك أو والدتك.",
        "device_admin_label" to "الرقابة الأبوية من OSRA",
        "device_admin_description" to "يتيح لـ OSRA قفل الجهاز، ويمنع إزالة التطبيق دون رمز PIN للوالدين.",
        "wipe_detected_notice" to "مُسحت بيانات OSRA على هذا الهاتف، لذلك لم يعد محميًا. اطلب من والدك أو والدتك إقرانه مرة أخرى.",
        // #473/#496, Q10 (Karim 2026-10-31 15:30Z): the block screen's window line.
        "block_window_line" to "محجوب بسبب %1\$s حتى %2\$s",
        "block_window_bedtime" to "وقت النوم",
        "block_window_school" to "الساعات المدرسية",
    )

    @Test
    fun `each system line has an English source and an Arabic counterpart`() {
        approvedArabic.keys.forEach { key ->
            assertTrue("English '$key' is missing", english.containsKey(key))
            assertTrue("Arabic '$key' is missing", arabic.containsKey(key))
        }
    }

    @Test
    fun `the Arabic is exactly the approved wording`() {
        approvedArabic.forEach { (key, approved) ->
            assertEquals("'$key' differs from the approved Arabic", approved, arabic.getValue(key))
        }
    }

    @Test
    fun `the Arabic window line keeps both placeholders, in order`() {
        // A translation that drops or swaps %1$s / %2$s would crash String.format or name the time as the window.
        listOf(english, arabic).forEach { strings ->
            val line = strings.getValue("block_window_line")
            assertTrue("'$line' must name the window first", line.indexOf("%1\$s") in 0 until line.indexOf("%2\$s"))
        }
    }

    @Test
    fun `the brand names keep the default value`() {
        listOf("app_name", "app_name_ar", "sos_tile_label").forEach { key ->
            assertFalse("'$key' is a brand name and should not be overridden in Arabic", arabic.containsKey(key))
        }
    }

    @Test
    fun `the block screen's Arabic is Karim's approved Q12, verbatim (#506)`() {
        // Karim approved all five at 16:28Z (quoted in full on this PR). Pinned as literals the way #487
        // and #502 pin theirs: a changed word, a dropped line or a partial translation turns this red, and
        // this pin is the only thing that would — nothing else reads `values-ar`.
        val approved = mapOf(
            "block_title_blocked" to "حجب والدك أو والدتك هذا التطبيق",
            "block_title_time_limit" to "انتهى وقت الشاشة اليومي",
            "block_request_access" to "اطلب السماح",
            "block_request_sent" to "أُرسل الطلب إلى والدك أو والدتك",
            "block_exit_home" to "الخروج إلى الشاشة الرئيسية",
        )
        approved.forEach { (key, wording) ->
            assertEquals("Arabic '$key'", wording, arabic.getValue(key))
        }
        approved.keys.forEach { key ->
            assertTrue("English '$key' is missing", english.containsKey(key))
        }
    }

    @Test
    fun `the block screen reads its words from resources, not from its own source (#506)`() {
        // The fault this catches is the one the Flip4 showed: the reason line Arabic, everything around it
        // English, because the sentences were literals in the composable. A literal here turns this red even
        // when the resource is also correct, which is the point — two sources of the same sentence drift.
        // Comments are stripped first: this file's KDoc quotes the sentences to explain the alert it posts,
        // and prose is not a second source of truth.
        val source = codeOnly(locate("src/main/java/com/familyshield/agent/enforcement/BlockActivity.kt").readText())
        listOf(
            "This app is blocked by your parent",
            "Daily limit reached",
            "Request access",
            "Request sent to your parent",
            "Exit to Home screen",
        ).forEach { wording ->
            assertFalse("'$wording' is hardcoded in BlockActivity", source.contains("\"$wording\""))
        }
        listOf(
            "R.string.block_title_blocked",
            "R.string.block_title_time_limit",
            "R.string.block_request_access",
            "R.string.block_request_sent",
            "R.string.block_exit_home",
        ).forEach { reference ->
            assertTrue("$reference is never read by BlockActivity", source.contains(reference))
        }
    }

    private fun strings(relativeToRes: String): Map<String, String> {
        val document = DocumentBuilderFactory.newInstance().newDocumentBuilder().parse(locate("src/main/res/$relativeToRes"))
        val nodes = document.getElementsByTagName("string")
        return (0 until nodes.length)
            .map { nodes.item(it) as Element }
            .associate { it.getAttribute("name") to it.textContent }
    }

    /** Strips block and line comments, so a source-text row judges code rather than prose. */
    private fun codeOnly(source: String): String =
        source.replace(Regex("/\\*[\\s\\S]*?\\*/"), "").replace(Regex("//[^\\n]*"), "")

    private fun locate(relativeToModule: String): File {
        val working = File(System.getProperty("user.dir") ?: ".").absoluteFile
        return listOf(File(working, relativeToModule), File(working, "app/$relativeToModule"))
            .firstOrNull { it.isFile }
            ?: error("could not find $relativeToModule below ${working.path}")
    }
}
