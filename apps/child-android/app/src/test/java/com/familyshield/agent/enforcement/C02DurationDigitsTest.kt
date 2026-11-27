package com.familyshield.agent.enforcement

import java.io.File
import java.util.Locale
import javax.xml.parsers.DocumentBuilderFactory
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import org.w3c.dom.Element

/**
 * Verifies the Arabic Language Bureau C-02 Western-digits follow-up (#1191 / #1188):
 * `c02_hours` and `c02_minutes` plurals use `%1$s` in both `values` and `values-ar`,
 * and `BlockActivity.formatDurationWords` formats counts with `Locale.US` so Arabic
 * locales (such as `ar-EG`) render Latin `0-9` digits instead of Arabic-Indic digits.
 *
 * Mutant: reverting `%1$s` back to `%1$d` in `values-ar/strings.xml` (or passing raw
 * `Int` args in `BlockActivity.formatDurationWords`) causes `String.format(arEg, ...)`
 * to emit Arabic-Indic `٥` for 5 minutes and fails this test.
 */
class C02DurationDigitsTest {

    private val arabicIndicDigits = Regex("[\\u0660-\\u0669]")

    private fun resFile(relPath: String): File {
        val candidates = listOf(
            File("src/main/res/$relPath"),
            File("app/src/main/res/$relPath"),
        )
        return candidates.firstOrNull { it.exists() }
            ?: error("Could not locate $relPath from ${File(".").absolutePath}")
    }

    private fun parsePlurals(file: File, name: String): Map<String, String> {
        val doc = DocumentBuilderFactory.newInstance().newDocumentBuilder().parse(file)
        val plurals = doc.getElementsByTagName("plurals")
        for (i in 0 until plurals.length) {
            val node = plurals.item(i) as Element
            if (node.getAttribute("name") == name) {
                val items = node.getElementsByTagName("item")
                val out = linkedMapOf<String, String>()
                for (j in 0 until items.length) {
                    val item = items.item(j) as Element
                    out[item.getAttribute("quantity")] = item.textContent
                }
                return out
            }
        }
        error("Missing <plurals name=\"$name\"> in ${file.path}")
    }

    private fun parseString(file: File, name: String): String {
        val doc = DocumentBuilderFactory.newInstance().newDocumentBuilder().parse(file)
        val strings = doc.getElementsByTagName("string")
        for (i in 0 until strings.length) {
            val node = strings.item(i) as Element
            if (node.getAttribute("name") == name) return node.textContent
        }
        error("Missing <string name=\"$name\"> in ${file.path}")
    }

    @Test
    fun `c02_hours and c02_minutes plurals use %1$s and never %1$d in values and values-ar`() {
        for (path in listOf("values/strings.xml", "values-ar/strings.xml")) {
            val file = resFile(path)
            for (pluralName in listOf("c02_hours", "c02_minutes")) {
                val items = parsePlurals(file, pluralName)
                assertTrue("$path:$pluralName must not be empty", items.isNotEmpty())
                for ((qty, text) in items) {
                    assertFalse(
                        "$path:$pluralName[$qty] must not use %1\$d (causes Arabic-Indic digits): $text",
                        text.contains("%1\$d") || text.contains("%d"),
                    )
                }
                assertTrue(
                    "$path:$pluralName[other] must use %1\$s",
                    items["other"]?.contains("%1\$s") == true,
                )
            }
        }
    }

    @Test
    fun `Arabic duration for 2 h 5 min and 3 h 12 min renders Latin digits under ar-EG locale`() {
        val arFile = resFile("values-ar/strings.xml")
        val hours = parsePlurals(arFile, "c02_hours")
        val mins = parsePlurals(arFile, "c02_minutes")
        val combo = parseString(arFile, "c02_hours_and_minutes")
        val arEg = Locale("ar", "EG")

        // 2 hours 5 minutes -> quantity two ("ساعتان") + quantity few ("%1$s دقائق")
        val twoHours = hours.getValue("two")
        val fiveMins = String.format(arEg, mins.getValue("few"), String.format(Locale.US, "%d", 5))
        val formatted2h5m = String.format(arEg, combo, twoHours, fiveMins)
        assertEquals("ساعتان و5 دقائق", formatted2h5m)
        assertTrue("Expected Latin digit 5 in '$formatted2h5m'", formatted2h5m.contains("5"))
        assertFalse(
            "Found Arabic-Indic digit in '$formatted2h5m'",
            arabicIndicDigits.containsMatchIn(formatted2h5m),
        )

        // 3 hours 12 minutes -> quantity few ("%1$s ساعات") + quantity many ("%1$s دقيقة")
        val threeHours = String.format(arEg, hours.getValue("few"), String.format(Locale.US, "%d", 3))
        val twelveMins = String.format(arEg, mins.getValue("many"), String.format(Locale.US, "%d", 12))
        val formatted3h12m = String.format(arEg, combo, threeHours, twelveMins)
        assertEquals("3 ساعات و12 دقيقة", formatted3h12m)
        assertFalse(
            "Found Arabic-Indic digit in '$formatted3h12m'",
            arabicIndicDigits.containsMatchIn(formatted3h12m),
        )
    }

    @Test
    fun `BlockActivity formatDurationWords passes Locale US formatted strings to getQuantityString`() {
        val candidates = listOf(
            File("src/main/java/com/familyshield/agent/enforcement/BlockActivity.kt"),
            File("app/src/main/java/com/familyshield/agent/enforcement/BlockActivity.kt"),
        )
        val src = candidates.firstOrNull { it.exists() }?.readText()
            ?: error("Could not locate BlockActivity.kt")
        assertTrue(
            "BlockActivity.formatDurationWords must format hours/mins with Locale.US",
            src.contains("Locale.US, \"%d\", hours") && src.contains("Locale.US, \"%d\", mins"),
        )
        assertFalse(
            "BlockActivity.formatDurationWords must not pass raw Int hours/mins to getQuantityString",
            src.contains("getQuantityString(R.plurals.c02_hours, hours, hours)") ||
                src.contains("getQuantityString(R.plurals.c02_minutes, mins, mins)"),
        )
    }
}
