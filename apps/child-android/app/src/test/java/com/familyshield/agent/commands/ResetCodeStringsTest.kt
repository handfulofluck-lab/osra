package com.familyshield.agent.commands

import java.io.File
import javax.xml.parsers.DocumentBuilderFactory
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import org.w3c.dom.Element

/**
 * ADR-0031's copy point, added in review: the child must be able to tell an adult rather than read
 * the code out to whoever asks, in English **and** Arabic.
 *
 * The Android resource merger is not on the JVM test classpath, so this reads the two source files
 * directly. That is exact for the questions asked here (same keys, real Arabic, the safety sentence
 * present in both) and costs no framework. The Arabic *rendering* — shaping, RTL, font sizes, and the
 * plural the device selects — needs a device and is out of scope, as the change's report says.
 */
class ResetCodeStringsTest {

    private val english = resourcesOf("values/strings.xml")
    private val arabic = resourcesOf("values-ar/strings.xml")

    @Test
    fun `every reset-code resource has an Arabic counterpart`() {
        assertEquals(
            "the two files must carry the same reset-code keys, strings and plurals alike",
            english.keys,
            arabic.keys,
        )
        assertTrue("the screen needs the title, intro pair, instruction, safety and close", english.keys.size >= 9)
    }

    @Test
    fun `the Arabic copy is Arabic, not a transliteration or an empty string`() {
        arabic.allValues().forEach { (key, value) ->
            assertTrue("'$key' has no Arabic characters: '$value'", Regex("[\\u0600-\\u06FF]").containsMatchIn(value))
        }
    }

    @Test
    fun `both languages name the parent in the intro`() {
        assertTrue(english.strings.getValue("reset_code_intro").contains("%1\$s"))
        assertTrue(arabic.strings.getValue("reset_code_intro").contains("%1\$s"))
    }

    @Test
    fun `a blank parent name falls back to generic copy rather than refusing the notice`() {
        // Finding 6: the API can send an empty or whitespace `displayName`, and the name is copy, not
        // the credential. Both files must carry an unnamed intro, and it must not read as a blank.
        listOf(english, arabic).forEach { resources ->
            val unnamed = resources.strings.getValue("reset_code_intro_unnamed")
            assertTrue("the unnamed intro must say something", unnamed.isNotBlank())
            assertFalse(
                "the unnamed intro must not depend on a name argument: '$unnamed'",
                unnamed.contains("%1\$s"),
            )
        }
    }

    @Test
    fun `the instruction is in person and never invites sending the code`() {
        val englishInstruction = english.strings.getValue("reset_code_instruction")
        val arabicInstruction = arabic.strings.getValue("reset_code_instruction")

        assertTrue("English must say 'in person'", englishInstruction.contains("in person"))
        assertTrue("English must tell the child not to send it", englishInstruction.contains("Do not send"))
        assertTrue("Arabic must say face to face", arabicInstruction.contains("وجهًا لوجه"))
        assertTrue("Arabic must tell the child not to send it", arabicInstruction.contains("لا ترسله"))
    }

    @Test
    fun `the safety line tells the child to refuse and to tell a trusted adult`() {
        val englishSafety = english.strings.getValue("reset_code_safety")
        val arabicSafety = arabic.strings.getValue("reset_code_safety")

        assertTrue(englishSafety.contains("say no"))
        assertTrue(englishSafety.contains("grown-up you trust"))
        assertTrue("OSRA must promise never to ask for the code", englishSafety.contains("never ask"))
        assertTrue(arabicSafety.contains("فارفض"))
        assertTrue(arabicSafety.contains("تثق به"))
        assertTrue(arabicSafety.contains("لن تطلب"))
    }

    @Test
    fun `the validity copy is a plural that takes the minutes from the payload`() {
        val englishPlural = english.plurals.getValue("reset_code_valid_for")
        val arabicPlural = arabic.plurals.getValue("reset_code_valid_for")

        assertTrue("English needs the singular form", englishPlural.getValue("one").contains("%1\$d minute"))
        assertTrue("and the plural form", englishPlural.getValue("other").contains("%1\$d minutes"))
        // The code lives for three to ten minutes most of the time, so the Arabic `few` is the form
        // the child usually reads.
        assertTrue("Arabic must take the minutes in the usual 3–10 form", arabicPlural.getValue("few").contains("%1\$d"))
        assertTrue("and in the 11+ form", arabicPlural.getValue("many").contains("%1\$d"))
    }

    @Test
    fun `Arabic uses the grammatical plural for one, two and three to ten`() {
        // Finding 3: "10 دقيقة" is wrong Arabic. The device picks the form, so every form must exist.
        val arabicPlural = arabic.plurals.getValue("reset_code_valid_for")

        assertEquals(
            "Arabic supplies all six CLDR quantities",
            setOf("zero", "one", "two", "few", "many", "other"),
            arabicPlural.keys,
        )
        assertTrue("one needs دقيقة واحدة", arabicPlural.getValue("one").contains("دقيقة واحدة"))
        assertTrue("two needs دقيقتين", arabicPlural.getValue("two").contains("دقيقتين"))
        assertTrue("three to ten need دقائق", arabicPlural.getValue("few").contains("دقائق"))
    }

    @Test
    fun `the notification copy is a hint and never carries the code`() {
        listOf(english, arabic).forEach { resources ->
            val text = resources.strings.getValue("reset_code_notification_text")
            assertTrue("the notification must tell the child what to do: '$text'", text.isNotBlank())
            assertFalse(
                "the notification must not be a format string for the code: '$text'",
                text.contains("%1\$"),
            )
        }
        assertTrue(english.strings.getValue("reset_code_notification_text").contains("in person"))
    }

    /** The `<string>` and `<plurals>` resources whose name starts `reset_code_` in one res directory. */
    private class ResourceFile(
        val strings: Map<String, String>,
        val plurals: Map<String, Map<String, String>>,
    ) {
        val keys: Set<String> get() = strings.keys + plurals.keys

        fun allValues(): Map<String, String> = buildMap {
            putAll(strings)
            plurals.forEach { (name, forms) -> forms.forEach { (quantity, text) -> put("$name[$quantity]", text) } }
        }
    }

    private fun resourcesOf(relativeToRes: String): ResourceFile {
        val file = locate("src/main/res/$relativeToRes")
        val document = DocumentBuilderFactory.newInstance().newDocumentBuilder().parse(file)

        val strings = elements(document, "string")
            .map { it.getAttribute("name") to it.textContent }
            .filter { (name, _) -> name.startsWith("reset_code_") }
            .toMap()

        val plurals = elements(document, "plurals")
            .filter { it.getAttribute("name").startsWith("reset_code_") }
            .associate { plural ->
                val items = plural.getElementsByTagName("item")
                val forms = (0 until items.length)
                    .map { items.item(it) as Element }
                    .associate { it.getAttribute("quantity") to it.textContent }
                plural.getAttribute("name") to forms
            }

        return ResourceFile(strings, plurals)
    }

    private fun elements(document: org.w3c.dom.Document, tag: String): List<Element> {
        val nodes = document.getElementsByTagName(tag)
        return (0 until nodes.length).map { nodes.item(it) as Element }
    }

    private fun locate(relativeToModule: String): File {
        val working = File(System.getProperty("user.dir") ?: ".").absoluteFile
        // Gradle runs unit tests with `apps/child-android` as the working directory; an IDE runner
        // may start at the repository root. These are source files, so a miss is a failure, not a skip.
        return listOf(File(working, relativeToModule), File(working, "app/$relativeToModule"))
            .firstOrNull { it.isFile }
            ?: error("could not find $relativeToModule below ${working.path}")
    }
}
