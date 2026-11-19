package com.familyshield.agent.security

import java.io.File
import javax.xml.parsers.DocumentBuilderFactory
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import org.w3c.dom.Element

/**
 * osra-security#24 / #792: the gate's notice while a lockout is open is a resource in both languages, and the
 * Arabic has six forms because Android picks the Arabic plural by the CLDR rule (1 `one`, 2 `two`, 3–10 `few`,
 * 11–99 `many`). With only `one`/`other`, "two minutes" would read «2 دقيقة» and five minutes «5 دقيقة», both
 * ungrammatical — the Arabic Language Bureau's review of the first version (comment 6885429894 on #725).
 *
 * Source-text rows, the [ChildSystemStringsTest] shape: a `getQuantityString` call needs a running Android and
 * a chosen locale, which a JVM test here does not have, so the file and its forms are judged directly.
 *
 * Mutants: drop any of the four extra Arabic forms → [the Arabic carries all six CLDR forms]; put `%1$d` into
 * `one` or `two` → [the one- and two-minute lines spell the number out in words]; change a word → [the Bureau's
 * line is byte for byte]; add a third English form → [English keeps its two forms].
 */
class PinLockedNoticeStringsTest {

    private fun plurals(relativeToRes: String): List<Element> {
        val file = locate("src/main/res/$relativeToRes")
        val document = DocumentBuilderFactory.newInstance().newDocumentBuilder().parse(file)
        val nodes = document.getElementsByTagName("plurals")
        val out = (0 until nodes.length)
            .map { nodes.item(it) as Element }
            .filter { it.getAttribute("name") == "pin_locked_notice" }
        assertEquals("exactly one pin_locked_notice in $relativeToRes", 1, out.size)
        val items = out[0].getElementsByTagName("item")
        return (0 until items.length).map { items.item(it) as Element }
    }

    private fun byQuantity(relativeToRes: String): Map<String, String> =
        plurals(relativeToRes).associate { it.getAttribute("quantity") to it.textContent.trim() }

    @Test
    fun `the Arabic carries all six CLDR forms`() {
        assertEquals(
            setOf("zero", "one", "two", "few", "many", "other"),
            byQuantity("values-ar/strings.xml").keys,
        )
    }

    @Test
    fun `English keeps its two forms`() {
        assertEquals(setOf("one", "other"), byQuantity("values/strings.xml").keys)
    }

    /** Arabic writes «دقيقة واحدة» and «دقيقتين»; printing a digit there is the defect the forms exist to avoid. */
    @Test
    fun `the one- and two-minute lines spell the number out in words`() {
        val ar = byQuantity("values-ar/strings.xml")
        assertFalse("one must not print a number", ar.getValue("one").contains("%1\$d"))
        assertFalse("two must not print a number", ar.getValue("two").contains("%1\$d"))
        assertTrue(ar.getValue("one").contains("دقيقة واحدة"))
        assertTrue(ar.getValue("two").contains("دقيقتين"))
    }

    /** The Bureau's line, verbatim; a reworded sentence is a documentation bug on a screen a child reads. */
    @Test
    fun `the Bureau's line is byte for byte`() {
        val ar = byQuantity("values-ar/strings.xml")
        assertEquals(
            "محاولات كثيرة. حاول مرة أخرى بعد %1\$d دقائق، أو اطلب المساعدة من والدك أو والدتك.",
            ar.getValue("few"),
        )
        assertEquals(
            "محاولات كثيرة. حاول مرة أخرى بعد %1\$d دقيقة، أو اطلب المساعدة من والدك أو والدتك.",
            ar.getValue("many"),
        )
        val en = byQuantity("values/strings.xml")
        assertEquals("Too many tries. Try again in %1\$d minute, or ask your parent.", en.getValue("one"))
        assertEquals("Too many tries. Try again in %1\$d minutes, or ask your parent.", en.getValue("other"))
    }

    private fun locate(relativeToModule: String): File {
        val working = File(System.getProperty("user.dir") ?: ".").absoluteFile
        return listOf(File(working, relativeToModule), File(working, "app/$relativeToModule"))
            .firstOrNull { it.isFile }
            ?: error("could not find $relativeToModule below ${working.path}")
    }
}
