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
        // The guard itself, because the JVM cannot reproduce the crash: Android's PBKDF2 provider throws
        // `password empty`, the JDK's silently computes a hash. A row that only calls verify("") passes
        // for the wrong reason - the hash does not match - so the length policy is asserted directly.
        assertFalse(ParentPin.hasAcceptedLength(""))
        assertFalse(ParentPin.hasAcceptedLength("47"))
        assertFalse(ParentPin.hasAcceptedLength("472912345"))
        assertTrue(ParentPin.hasAcceptedLength("4729"))
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

    /**
     * osra-security#17: an empty submit used to reach PBKDF2, which can throw on Android; the throw
     * took the agent process down and enforcement stopped with it.
     *
     * Both halves are pinned here: the verifier answers false instead of throwing, and an input outside
     * the accepted length never reaches the KDF at all. Mutant: drop the length guard -> the empty and
     * too-short rows throw instead of returning false.
     */
    @Test
    fun `an empty or out-of-range pin is a wrong pin, never an exception`() {
        val stored = ParentPin.hash("4729")
        assertFalse(ParentPin.verify("", stored))
        assertFalse(ParentPin.verify("", "pbkdf2\$120000\$AAAA\$AAAA"))
        assertFalse(ParentPin.verify("47", stored))
        assertFalse(ParentPin.verify("472912345", stored))
        // and the happy path still works, so the guard has not simply disabled verification
        assertTrue(ParentPin.verify("4729", stored))
    }

    /**
     * Claude's two points on #761: the guards inside `verify` were not pinned by anything, because the JVM's
     * PBKDF2 provider accepts an empty password where Android's throws — so the pre-fix `verify` (fault m1)
     * answered `false` for the wrong reason and stayed green. The KDF seam makes both rows possible.
     */
    @Test
    fun `a KDF that throws is a wrong pin, not a crash`() {
        val stored = ParentPin.hash("4729")
        val throwing = { _: String, _: ByteArray, _: Int -> throw IllegalArgumentException("password empty") }
        assertFalse(ParentPin.verify("4729", stored, throwing))
    }

    @Test
    fun `an out-of-range pin never reaches the KDF`() {
        val stored = ParentPin.hash("4729")
        var calls = 0
        val recording = { _: String, _: ByteArray, _: Int -> calls += 1; ByteArray(32) }
        assertFalse(ParentPin.verify("", stored, recording))
        assertFalse(ParentPin.verify("47", stored, recording))
        assertFalse(ParentPin.verify("472912345", stored, recording))
        assertEquals(0, calls)
        // and the guard is not simply "never calls": an accepted length does reach it
        ParentPin.verify("4729", stored, recording)
        assertEquals(1, calls)
    }
}
