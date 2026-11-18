package com.familyshield.agent.setup

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * #728: the rules the new pairing screen draws, driven here rather than through a device.
 *
 * Mutants, one per row: let [PairingScreenState.onDigit] accept any character → [letters are not a code];
 * drop the `code.length != 6` guard in [PairingScreenState.onPaste] → [a partial paste leaves the cells alone];
 * drop the `!waiting` guard → [nothing changes while the claim is in flight]; return the digits un-folded →
 * [Arabic-Indic digits are folded to Western].
 */
class PairingScreenStateTest {

    private fun typed(text: String): PairingScreenState =
        text.fold(PairingScreenState()) { state, ch -> state.onDigit(ch) }

    @Test
    fun `six digits make the button ready and five do not`() {
        assertFalse(PairingScreenState().canSubmit)
        assertFalse(typed("12345").canSubmit)
        assertTrue(typed("123456").canSubmit)
        assertEquals("123456", typed("123456").digits)
    }

    @Test
    fun `a seventh digit is ignored, so the cells cannot overflow`() {
        assertEquals("123456", typed("1234567").digits)
    }

    @Test
    fun `letters are not a code`() {
        assertEquals("123", typed("1a2b3").digits)
        assertEquals("", typed("abcdef").digits)
    }

    /** The clipboard usually holds a whole message; the six digits are taken out of it. */
    @Test
    fun `a paste of a message fills the cells from the digits inside it`() {
        val state = PairingScreenState().onPaste("Pairing code: 482913 — it expires in 10 minutes")
        assertEquals("482913", state.digits)
        assertTrue(state.canSubmit)
    }

    @Test
    fun `a partial paste leaves the cells alone`() {
        val state = PairingScreenState(digits = "12").onPaste("349")
        assertEquals("12", state.digits)
    }

    /** Issue #771's class of bug: ٠–٩ typed by an Arabic keyboard must be the same code the server compares. */
    @Test
    fun `Arabic-Indic digits are folded to Western`() {
        assertEquals("012345", typed("٠١٢٣٤٥").digits)
        assertEquals("012345", typed("۰۱۲۳۴۵").digits)
        assertEquals("482913", PairingScreenState().onPaste("٤٨٢٩١٣").digits)
    }

    @Test
    fun `backspace empties the last cell and clears the error line`() {
        val state = PairingScreenState(digits = "4829", error = "Wrong code").onBackspace()
        assertEquals("482", state.digits)
        assertNull("an error goes as soon as the parent types", state.error)
        assertEquals("", PairingScreenState().onBackspace().digits)
    }

    @Test
    fun `nothing changes while the claim is in flight`() {
        val waiting = typed("482913").submitting()
        assertTrue(waiting.waiting)
        assertEquals("482913", waiting.onDigit('7').digits)
        assertEquals("482913", waiting.onBackspace().digits)
        assertEquals("482913", waiting.onPaste("111111").digits)
        assertEquals("", waiting.onName("Alex").deviceName)
        assertFalse("and the button cannot be pressed twice", waiting.canSubmit)
    }

    @Test
    fun `an incomplete code cannot be submitted`() {
        val state = typed("48291").submitting()
        assertFalse("five digits is not a claim", state.waiting)
    }

    @Test
    fun `a failure shows one line and ends the wait`() {
        val failed = typed("482913").submitting().failed("That code has expired.")
        assertFalse(failed.waiting)
        assertEquals("That code has expired.", failed.error)
        assertTrue("the cells keep the code so the parent can correct one digit", failed.digits == "482913")
    }

    @Test
    fun `typing again clears the error`() {
        val state = PairingScreenState(error = "That code has expired.").onDigit('4')
        assertNull(state.error)
    }

    @Test
    fun `the name is optional and capped`() {
        assertEquals("", PairingScreenState().deviceName)
        assertEquals("Alex's phone", PairingScreenState().onName("Alex's phone").deviceName)
        assertEquals(
            PairingScreenState.NAME_MAX_LENGTH,
            PairingScreenState().onName("x".repeat(200)).deviceName.length,
        )
    }
}
