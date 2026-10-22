package com.familyshield.agent.commands

import java.io.File
import javax.xml.parsers.DocumentBuilderFactory
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import org.w3c.dom.Element

/**
 * ADR-0031's copy point, added in review: the child must be able to tell an adult rather than read
 * the code out to whoever asks, in English **and** Arabic.
 *
 * The Android resource merger is not on the JVM test classpath, so this reads the two source files
 * directly. That is exact for the questions asked here (same keys, real Arabic, the safety sentence
 * present in both) and costs no framework. The Arabic *rendering* — shaping, RTL, font sizes — needs
 * a device and is out of scope, as the change's report says.
 */
class ResetCodeStringsTest {

    private val english = stringsOf("values/strings.xml")
    private val arabic = stringsOf("values-ar/strings.xml")

    @Test
    fun `every reset-code string has an Arabic counterpart`() {
        assertEquals(
            "the two files must carry the same reset-code keys",
            english.keys,
            arabic.keys,
        )
        assertTrue("the screen needs at least a title and a safety line", english.size >= 7)
    }

    @Test
    fun `the Arabic copy is Arabic, not a transliteration or an empty string`() {
        arabic.forEach { (key, value) ->
            assertTrue("'$key' has no Arabic characters: '$value'", Regex("[\\u0600-\\u06FF]").containsMatchIn(value))
        }
    }

    @Test
    fun `both languages name the parent in the intro`() {
        assertTrue(english.getValue("reset_code_intro").contains("%1\$s"))
        assertTrue(arabic.getValue("reset_code_intro").contains("%1\$s"))
    }

    @Test
    fun `the instruction is in person and never invites sending the code`() {
        val englishInstruction = english.getValue("reset_code_instruction")
        val arabicInstruction = arabic.getValue("reset_code_instruction")

        assertTrue("English must say 'in person'", englishInstruction.contains("in person"))
        assertTrue("English must tell the child not to send it", englishInstruction.contains("Do not send"))
        assertTrue("Arabic must say face to face", arabicInstruction.contains("وجهًا لوجه"))
        assertTrue("Arabic must tell the child not to send it", arabicInstruction.contains("لا ترسله"))
    }

    @Test
    fun `the safety line tells the child to refuse and to tell a trusted adult`() {
        val englishSafety = english.getValue("reset_code_safety")
        val arabicSafety = arabic.getValue("reset_code_safety")

        assertTrue(englishSafety.contains("say no"))
        assertTrue(englishSafety.contains("grown-up you trust"))
        assertTrue("OSRA must promise never to ask for the code", englishSafety.contains("never ask"))
        assertTrue(arabicSafety.contains("فارفض"))
        assertTrue(arabicSafety.contains("تثق به"))
        assertTrue(arabicSafety.contains("لن تطلب"))
    }

    @Test
    fun `the validity copy takes the minutes from the payload, not a fixed sentence`() {
        assertTrue(english.getValue("reset_code_valid_for").contains("%1\$d"))
        assertTrue(arabic.getValue("reset_code_valid_for").contains("%1\$d"))
    }

    /** Reads `<string>` nodes whose name starts `reset_code_` from a resource directory. */
    private fun stringsOf(relativeToRes: String): Map<String, String> {
        val file = locate("src/main/res/$relativeToRes")
        val document = DocumentBuilderFactory.newInstance().newDocumentBuilder().parse(file)
        val nodes = document.getElementsByTagName("string")
        return (0 until nodes.length)
            .map { nodes.item(it) as Element }
            .map { it.getAttribute("name") to it.textContent }
            .filter { (name, _) -> name.startsWith("reset_code_") }
            .toMap()
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
