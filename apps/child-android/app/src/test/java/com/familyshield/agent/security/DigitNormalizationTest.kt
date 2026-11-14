package com.familyshield.agent.security

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.util.Base64
import javax.crypto.SecretKeyFactory
import javax.crypto.spec.PBEKeySpec

class DigitNormalizationTest {
    private fun legacyHash(pin: String): String {
        val salt = ByteArray(16)
        val spec = PBEKeySpec(pin.toCharArray(), salt, 120000, 256)
        val hash = SecretKeyFactory.getInstance("PBKDF2WithHmacSHA256").generateSecret(spec).encoded
        val encoder = Base64.getEncoder()
        return "pbkdf2\$120000\$${encoder.encodeToString(salt)}\$${encoder.encodeToString(hash)}"
    }

    @Test
    fun `maps approved digit sets mixed forms spaces and marks`() {
        assertEquals("0123456", normalizeDigits("٠١٢٣٤٥٦"))
        assertEquals("123456", normalizeDigits("۱۲۳۴۵۶"))
        assertEquals("012233445566", normalizeDigits("٠1٢2۳3۴4۵5۶6"))
        assertEquals("12345678", normalizeDigits("1٢3۴ 5\u200E6\u200F7\u061C8"))
    }

    @Test
    fun `refuses full width other scripts and every other character`() {
        for (value in listOf("１２３４５６", "১২৩৪৫৬", "१२३४५६", "12a456", "123\n456", "123\t456")) {
            assertNull(value, normalizeDigits(value))
        }
    }

    @Test
    fun `validation and hashing store only the normalized pin`() {
        assertNull(ParentPin.validationError("٤٧٢٩"))
        assertNull(ParentPin.validationError("۴۷۲۹"))
        assertEquals("PIN must be digits only.", ParentPin.validationError("４７２９"))
        val stored = ParentPin.hash("٤٧٢٩")
        assertTrue(ParentPin.verify("4729", stored))
        assertTrue(ParentPin.verify("٤٧٢٩", stored))
        assertTrue(ParentPin.verify("۴۷۲۹", stored))
        assertFalse(ParentPin.verify("４７２９", stored))
    }

    @Test
    fun `legacy localized hash opens once and is replaced with normalized hash`() {
        var stored = legacyHash("٤٧٢٩")
        assertTrue(ParentPin.verifyAndMigrate("٤٧٢٩", stored) { stored = it })
        assertTrue(ParentPin.verify("٤٧٢٩", stored))
        assertTrue(ParentPin.verify("۴۷۲۹", stored))
        assertFalse(ParentPin.verify("4728", stored))
    }
}
