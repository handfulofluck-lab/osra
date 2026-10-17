package com.familyshield.agent.security

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** ADR-0010: the parent PIN is hashed (PBKDF2, salted), verified constant-time, and weak PINs are refused. */
class ParentPinTest {

    @Test
    fun `hash never stores the pin and verifies only the right one`() {
        val stored = ParentPin.hash("4729")
        assertTrue(stored.startsWith("pbkdf2$"))
        assertFalse(stored.contains("4729"))
        assertTrue(ParentPin.verify("4729", stored))
        assertFalse(ParentPin.verify("4728", stored))
        assertFalse(ParentPin.verify("", stored))
    }

    @Test
    fun `two hashes of the same pin differ (fresh salt) and both verify`() {
        val a = ParentPin.hash("583921")
        val b = ParentPin.hash("583921")
        assertNotEquals(a, b)
        assertTrue(ParentPin.verify("583921", a))
        assertTrue(ParentPin.verify("583921", b))
    }

    @Test
    fun `malformed or missing stored values never verify`() {
        assertFalse(ParentPin.verify("4729", null))
        assertFalse(ParentPin.verify("4729", ""))
        assertFalse(ParentPin.verify("4729", "plain:4729"))
        assertFalse(ParentPin.verify("4729", "pbkdf2\$abc\$salt\$hash"))
        assertFalse(ParentPin.verify("4729", "pbkdf2\$120000\$not-base64!\$x"))
    }

    @Test
    fun `validation refuses short, long, non-digit, repeated and well-known pins`() {
        assertNull(ParentPin.validationError("4729"))
        assertNull(ParentPin.validationError("58392176"))
        assertEquals("PIN must be at least 4 digits.", ParentPin.validationError("472"))
        assertEquals("PIN must be at most 8 digits.", ParentPin.validationError("472947294"))
        assertEquals("PIN must be digits only.", ParentPin.validationError("47a9"))
        assertEquals("Choose a PIN that is not all the same digit.", ParentPin.validationError("7777"))
        assertEquals("Choose a less predictable PIN.", ParentPin.validationError("1234"))
        assertEquals("Choose a less predictable PIN.", ParentPin.validationError("123456"))
    }
}
