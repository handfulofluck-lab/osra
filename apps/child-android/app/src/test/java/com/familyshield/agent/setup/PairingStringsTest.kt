package com.familyshield.agent.setup

import java.io.File
import javax.xml.parsers.DocumentBuilderFactory
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import org.w3c.dom.Element

/**
 * Plan 2.7 (#433, #439): the pairing screen and the parent-PIN step after it read their copy from
 * resources, and the Arabic is exactly what Karim approved on #439 (2026-10-29 08:54Z). Each line is
 * pinned as a literal, so a changed or missing translation turns this red rather than passing because
 * it looked itself up.
 *
 * As in `ResetCodeStringsTest`, the resource merger is not on the JVM test classpath, so this reads the
 * two source files. The Arabic *rendering* (shaping, RTL, the screen itself) needs a device.
 */
class PairingStringsTest {

    private val english = pairingStrings("values/strings.xml")
    private val arabic = pairingStrings("values-ar/strings.xml")

    /** Karim's approved Arabic, line for line. */
    private val approvedArabic = linkedMapOf(
        "pair_intro" to "أقرن هذا الجهاز بخادم OSRA الخاص بك.",
        "pair_server_label" to "عنوان الخادم",
        "pair_code_label" to "رمز الإقران",
        "pair_name_label" to "اسم الجهاز",
        "pair_name_hint" to "اسم الجهاز (اختياري)",
        "pair_button" to "أقرن هذا الجهاز",
        "pair_scan_button" to "امسح رمز QR",
        "pair_scan_description" to "امسح رمز QR للإقران من تطبيق الوالدين",
        "pair_scanned_title" to "تفاصيل الإقران الممسوحة",
        "pair_scanned_server" to "الخادم: %1\$s",
        "pair_scanned_code" to "الرمز: %1\$s",
        "pair_scanned_check" to "تأكد من أنها تطابق ما يظهر على شاشة والدك أو والدتك. لن يتم الإقران حتى تؤكد.",
        "pair_confirm_button" to "أكّد وأقرن",
        "pair_cancel" to "إلغاء",
        "pair_error_server" to "أدخل عنوان الخادم الذي أعطاك إياه والدك أو والدتك.",
        "pair_error_code" to "أدخل رمز الإقران المكوّن من 6 أرقام.",
        "pair_error_rescan" to "امسح رمز QR مرة أخرى قبل التأكيد.",
        "pair_no_camera" to "الكاميرا غير متاحة على هذا الجهاز. أدخل عنوان الخادم والرمز يدويًا.",
        "pair_waiting" to "بانتظار أن يضغط والدك أو والدتك على «سماح» في هاتفه…",
        "pair_denied" to "رفض والدك أو والدتك هذا الهاتف. إذا كان ذلك خطأ، فاطلب رمزًا جديدًا.",
        "pair_expired" to "انتهت صلاحية الرمز قبل أن يسمح والدك أو والدتك بهذا الهاتف. اطلب رمزًا جديدًا.",
        "pair_in_use" to "هذا الرمز مستخدم بالفعل على هاتف آخر. اطلب من والدك أو والدتك رمزًا جديدًا.",
        "pair_consent" to "يجب أن يمنح والدك أو والدتك الموافقة في تطبيق OSRA قبل إقران هذا الهاتف.",
        "pair_invalid_code" to "رمز الإقران غير صالح أو منتهي الصلاحية.",
        "pair_failed" to "فشل الإقران: %1\$s",
        "pair_pin_title" to "تم الإقران. عيّن الآن رمز PIN الخاص بالوالدين",
        "pair_pin_body" to "يُطلب هذا الرمز كلما حاول أحد إزالة حماية OSRA عن هذا الجهاز (إيقاف مشرف الجهاز، أو إلغاء التثبيت، أو إعادة الإقران). احتفظ به لنفسك، ولا تُطلع طفلك عليه.",
        "pair_pin_label" to "رمز PIN للوالدين",
        "pair_pin_hint" to "من 4 إلى 8 أرقام",
        "pair_pin_repeat" to "أعد إدخال الرمز",
        "pair_pin_save" to "احفظ الرمز",
        "pair_pin_mismatch" to "الرمزان غير متطابقين.",
        // Karim, 2026-10-29 11:43Z (#440): the scanner and network lines.
        "pair_qr_invalid" to "رمز QR هذا ليس رمز إقران صالحًا من OSRA. أدخل التفاصيل يدويًا أو امسح مرة أخرى.",
        "pair_scan_empty" to "لم يُرجع الماسح أي رمز. أدخل التفاصيل يدويًا أو امسح مرة أخرى.",
        "pair_network_error" to "خطأ في الشبكة",
    )

    @Test
    fun `every pairing string has an Arabic counterpart, and nothing extra`() {
        assertEquals(english.keys, arabic.keys)
        assertEquals(approvedArabic.keys, arabic.keys)
    }

    @Test
    fun `the Arabic is exactly the approved wording`() {
        approvedArabic.forEach { (key, approved) ->
            assertEquals("'$key' differs from the approved Arabic", approved, arabic.getValue(key))
        }
    }

    @Test
    fun `the format arguments survive translation`() {
        listOf("pair_scanned_server", "pair_scanned_code", "pair_failed").forEach { key ->
            assertTrue("English '$key' lost %1\$s", english.getValue(key).contains("%1\$s"))
            assertTrue("Arabic '$key' lost %1\$s", arabic.getValue(key).contains("%1\$s"))
        }
    }

    @Test
    fun `wherever the English says your parent, the Arabic names both parents`() {
        english.filterValues { it.contains("your parent", ignoreCase = true) }.keys.forEach { key ->
            assertTrue("'$key' should say والدك أو والدتك", arabic.getValue(key).contains("والدك أو والدتك"))
        }
    }

    private fun pairingStrings(relativeToRes: String): Map<String, String> {
        val document = DocumentBuilderFactory.newInstance().newDocumentBuilder().parse(locate("src/main/res/$relativeToRes"))
        val nodes = document.getElementsByTagName("string")
        return (0 until nodes.length)
            .map { nodes.item(it) as Element }
            .filter { it.getAttribute("name").startsWith("pair_") }
            .associate { it.getAttribute("name") to it.textContent }
    }

    private fun locate(relativeToModule: String): File {
        val working = File(System.getProperty("user.dir") ?: ".").absoluteFile
        return listOf(File(working, relativeToModule), File(working, "app/$relativeToModule"))
            .firstOrNull { it.isFile }
            ?: error("could not find $relativeToModule below ${working.path}")
    }
}
