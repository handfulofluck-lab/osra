package com.familyshield.agent.setup

import java.io.File
import javax.xml.parsers.DocumentBuilderFactory
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import org.w3c.dom.Element

/**
 * #728: the pairing screen's words are the two Bureaus' and they are copied, not paraphrased. This pins them.
 *
 * The English is the UI/UX Bureau's design (comment 6861894747) with the Arabic Language Bureau's corrections
 * (6861943604); the Arabic is that comment byte for byte. A row per line, because "we translated it carefully" is
 * not a fact anyone can check later.
 *
 * Mutant: change a word in either file → the row for that line goes red.
 */
class PairingCopyStringsTest {

    private fun strings(relativeToRes: String): Map<String, String> {
        val file = locate("src/main/res/$relativeToRes")
        val document = DocumentBuilderFactory.newInstance().newDocumentBuilder().parse(file)
        val nodes = document.getElementsByTagName("string")
        return (0 until nodes.length).map { nodes.item(it) as Element }
            .associate { it.getAttribute("name") to it.textContent }
    }

    private fun locate(relativeToModule: String): File {
        val working = File(System.getProperty("user.dir") ?: ".").absoluteFile
        return listOf(File(working, relativeToModule), File(working, "app/$relativeToModule"))
            .firstOrNull { it.isFile }
            ?: error("could not find $relativeToModule below ${working.path}")
    }

    @Test
    fun `the English is the Bureau's, line by line`() {
        val en = strings("values/strings.xml")
        assertEquals("Pair this device with your family", en["pair_title"])
        assertEquals(
            "Open OSRA on a parent's phone, choose Pair a device, then scan the code it shows.",
            en["pair_intro"],
        )
        assertEquals("or type the pairing code", en["pair_or_type_code"])
        assertEquals("Waiting for Allow…", en["pair_button_waiting_allow"])
        assertEquals(
            "Monitoring starts only after a parent allows this device in the OSRA app.",
            en["pair_reassurance"],
        )
        assertEquals("Use your own server", en["pair_use_own_server"])
    }

    @Test
    fun `the Arabic is the Bureau's, line by line`() {
        val ar = strings("values-ar/strings.xml")
        assertEquals("أقرن هذا الجهاز بعائلتك", ar["pair_title"])
        assertEquals(
            "افتح تطبيق أسرة على هاتف أحد الوالدين، واختر «إقران جهاز»، ثم امسح الرمز الذي يظهر.",
            ar["pair_intro"],
        )
        assertEquals("أو اكتب رمز الإقران", ar["pair_or_type_code"])
        assertEquals("بانتظار السماح…", ar["pair_button_waiting_allow"])
        assertEquals(
            "لا تبدأ المراقبة إلا بعد أن يسمح أحد الوالدين بهذا الجهاز في تطبيق أسرة.",
            ar["pair_reassurance"],
        )
        assertEquals("استخدم خادمك الخاص", ar["pair_use_own_server"])
    }

    /** The Bureau's rule: no Arabic line on this screen starts with a Latin word or a digit. */
    @Test
    fun `no Arabic line starts with a Latin letter or a digit`() {
        val ar = strings("values-ar/strings.xml")
        for (key in listOf(
            "pair_title", "pair_intro", "pair_or_type_code", "pair_button_waiting_allow",
            "pair_reassurance", "pair_use_own_server",
        )) {
            val first = ar.getValue(key).trim().first()
            assertTrue("$key starts with '$first'", !(first in 'a'..'z' || first in 'A'..'Z' || first in '0'..'9'))
        }
    }
}
