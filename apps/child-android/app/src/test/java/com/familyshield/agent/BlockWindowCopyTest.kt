package com.familyshield.agent

import com.familyshield.agent.data.WindowKind
import com.familyshield.agent.data.WindowReason
import com.familyshield.agent.enforcement.BlockWindowCopy
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

/**
 * Issue #473: the block screen names the window that is holding the app shut, so a child in a Study
 * routine and a child kept out of school hours stop reading the same sentence.
 *
 * The screen itself is Compose and needs a device; the sentence — and which reason produces which
 * sentence, or none — is a decision, and that is what these rows pin.
 *
 * Issue #506: **every value that goes into the template is wrapped in FSI…PDI** (U+2068 / U+2069), so a
 * routine the family named in English cannot trade places with the time on an Arabic phone. The expected
 * strings are pinned with the isolates spelled out in [iso], and the two #506 rows spell them as the
 * codepoints U+2068 and U+2069, so a different wrapper — or none — turns them red rather than passing
 * quietly.
 *
 * Mutants: return a line for a null window, and [no window means no sentence] goes red; localise the
 * routine name instead of using it verbatim, and [a routine is named by the family] goes red; drop
 * [iso] and the three #506 rows go red.
 */
class BlockWindowCopyTest {

    @Test
    fun `school hours are named with their end`() {
        assertEquals(
            "Blocked by ${iso("School hours")} until ${iso("15:00")}",
            BlockWindowCopy.line(WindowReason(WindowKind.SCHOOL, null, "15:00"), BEDTIME, SCHOOL, TEMPLATE),
        )
    }

    @Test
    fun `bedtime is named with its end`() {
        assertEquals(
            "Blocked by ${iso("Bedtime")} until ${iso("07:00")}",
            BlockWindowCopy.line(WindowReason(WindowKind.BEDTIME, null, "07:00"), BEDTIME, SCHOOL, TEMPLATE),
        )
    }

    @Test
    fun `a routine is named by the family`() {
        assertEquals(
            "Blocked by ${iso("Homework")} until ${iso("19:00")}",
            BlockWindowCopy.line(WindowReason(WindowKind.ROUTINE, "Homework", "19:00"), BEDTIME, SCHOOL, TEMPLATE),
        )
    }

    @Test
    fun `a routine with a blank name says nothing rather than half a sentence`() {
        assertNull(BlockWindowCopy.line(WindowReason(WindowKind.ROUTINE, "  ", "19:00"), BEDTIME, SCHOOL, TEMPLATE))
    }

    @Test
    fun `no window means no sentence`() {
        // Every other reason — a pause, an explicit block, a time limit, the blocklist — arrives here as
        // null, and the screen keeps today's copy.
        assertNull(BlockWindowCopy.line(null, BEDTIME, SCHOOL, TEMPLATE))
    }

    @Test
    fun `the words come from the caller, so an Arabic phone can show Arabic (#496 review)`() {
        // The first version built "Bedtime" and the template in Kotlin; this row fails if that returns.
        val arabic = BlockWindowCopy.line(
            WindowReason(WindowKind.SCHOOL, null, "15:00"),
            bedtime = ARABIC_BEDTIME,
            schoolHours = ARABIC_SCHOOL,
            template = ARABIC_TEMPLATE,
        )
        assertEquals("محجوب بسبب ${iso(ARABIC_SCHOOL)} حتى ${iso("15:00")}", arabic)
    }

    @Test
    fun `an English routine name keeps its place in an Arabic sentence (#506)`() {
        // The Flip4 rendering of exactly this input was «محجوب بسبب Homework 23:50 حتى»: the Latin name and
        // the digits after it swapped under the bidi algorithm, so the sentence named the time as the window
        // and the window as the time. The isolates are pinned as codepoints, not as characters.
        val line = BlockWindowCopy.line(
            WindowReason(WindowKind.ROUTINE, "Homework", "23:50"),
            bedtime = ARABIC_BEDTIME,
            schoolHours = ARABIC_SCHOOL,
            template = ARABIC_TEMPLATE,
        )
        assertEquals("محجوب بسبب \u2068Homework\u2069 حتى \u206823:50\u2069", line)
        // And they are zero-width: strip them and the sentence a reader actually sees is unchanged.
        assertEquals(
            "محجوب بسبب Homework حتى 23:50",
            line!!.replace("\u2068", "").replace("\u2069", ""),
        )
    }

    @Test
    fun `an Arabic routine name is wrapped the same way (#506)`() {
        val line = BlockWindowCopy.line(
            WindowReason(WindowKind.ROUTINE, "واجب", "23:50"),
            bedtime = ARABIC_BEDTIME,
            schoolHours = ARABIC_SCHOOL,
            template = ARABIC_TEMPLATE,
        )
        assertEquals("محجوب بسبب \u2068واجب\u2069 حتى \u206823:50\u2069", line)
    }

    @Test
    fun `English output is unchanged once the isolates are stripped (#506)`() {
        // An English phone must not start showing anything odd because of a fix aimed at Arabic.
        val line = BlockWindowCopy.line(
            WindowReason(WindowKind.ROUTINE, "Homework", "19:00"), BEDTIME, SCHOOL, TEMPLATE,
        )!!
        assertEquals("Blocked by Homework until 19:00", line.replace("\u2068", "").replace("\u2069", ""))
    }

    private companion object {
        const val BEDTIME = "Bedtime"
        const val SCHOOL = "School hours"
        const val TEMPLATE = "Blocked by %1\$s until %2\$s"

        const val ARABIC_BEDTIME = "وقت النوم"
        const val ARABIC_SCHOOL = "الساعات المدرسية"
        const val ARABIC_TEMPLATE = "محجوب بسبب %1\$s حتى %2\$s"

        /** The wrapper `BlockWindowCopy` applies: first-strong isolate, then pop directional isolate. */
        fun iso(value: String): String = "\u2068$value\u2069"
    }
}
