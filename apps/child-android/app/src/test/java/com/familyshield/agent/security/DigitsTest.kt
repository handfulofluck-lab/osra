package com.familyshield.agent.security

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/** #771: Arabic-Indic and Extended Arabic-Indic digits are the same digits before any check. */
class DigitsTest {

    @Test
    fun `maps both Arabic digit families to Western digits`() {
        assertEquals("0123456789", Digits.normalize("٠١٢٣٤٥٦٧٨٩"))
        assertEquals("0123456789", Digits.normalize("۰۱۲۳۴۵۶۷۸۹"))
        assertEquals("1234", Digits.normalize("1٢3۴"))
        assertEquals("4729", Digits.normalize("4729"))
    }

    @Test
    fun `leaves anything that is not a digit alone`() {
        assertEquals("a-٥.b", Digits.normalize("a-٥.b"))
    }

    @Test
    fun `isAsciiDigits is true only for non-empty all-digit input after normalisation`() {
        assertTrue(Digits.isAsciiDigits("٤٧٢٩"))
        assertTrue(Digits.isAsciiDigits("۴۷۲۹"))
        assertTrue(Digits.isAsciiDigits("4729"))
        assertFalse(Digits.isAsciiDigits(""))
        assertFalse(Digits.isAsciiDigits("47a9"))
        assertFalse(Digits.isAsciiDigits("½"))
    }
}
