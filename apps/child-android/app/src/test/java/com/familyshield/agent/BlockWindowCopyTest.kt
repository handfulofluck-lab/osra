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
 * Mutants: return a line for a null window, and [no window means no sentence] goes red; localise the
 * routine name instead of using it verbatim, and [a routine is named by the family] goes red.
 */
class BlockWindowCopyTest {

    @Test
    fun `school hours are named with their end`() {
        assertEquals(
            "Blocked by School hours until 15:00",
            BlockWindowCopy.line(WindowReason(WindowKind.SCHOOL, null, "15:00"), BEDTIME, SCHOOL, TEMPLATE),
        )
    }

    @Test
    fun `bedtime is named with its end`() {
        assertEquals(
            "Blocked by Bedtime until 07:00",
            BlockWindowCopy.line(WindowReason(WindowKind.BEDTIME, null, "07:00"), BEDTIME, SCHOOL, TEMPLATE),
        )
    }

    @Test
    fun `a routine is named by the family`() {
        assertEquals(
            "Blocked by Homework until 19:00",
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
            bedtime = "وقت النوم",
            schoolHours = "الساعات المدرسية",
            template = "محجوب حتى %2\$s بسبب %1\$s",
        )
        assertEquals("محجوب حتى 15:00 بسبب الساعات المدرسية", arabic)
    }

    private companion object {
        const val BEDTIME = "Bedtime"
        const val SCHOOL = "School hours"
        const val TEMPLATE = "Blocked by %1\$s until %2\$s"
    }
}
