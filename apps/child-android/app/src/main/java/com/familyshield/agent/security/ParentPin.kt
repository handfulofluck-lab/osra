package com.familyshield.agent.security

import java.security.MessageDigest
import java.security.SecureRandom
import javax.crypto.SecretKeyFactory
import javax.crypto.spec.PBEKeySpec

/**
 * Pure, dependency-free parent-PIN hashing and verification (ADR-0010). Kept free of Android types
 * so the whole policy is unit-tested on the JVM. The PIN gates every protection-removal action on
 * the device — disabling Device Admin, re-pairing, stopping the lock overlay — so it must never be
 * stored or compared in the clear.
 *
 * Storage format: `pbkdf2$<iterations>$<saltB64>$<hashB64>`. Verification is constant-time.
 */
object ParentPin {
    private const val ITERATIONS = 120_000
    private const val KEY_BITS = 256
    private const val SALT_BYTES = 16
    const val MIN_LENGTH = 4
    const val MAX_LENGTH = 8

    /** A PIN is 4–8 digits. Returns null when acceptable, else a human-readable reason. */
    fun validationError(pin: String): String? = when {
        pin.length < MIN_LENGTH -> "PIN must be at least $MIN_LENGTH digits."
        pin.length > MAX_LENGTH -> "PIN must be at most $MAX_LENGTH digits."
        !pin.all { it.isDigit() } -> "PIN must be digits only."
        pin.toSet().size == 1 -> "Choose a PIN that is not all the same digit."
        pin in WEAK_PINS -> "Choose a less predictable PIN."
        else -> null
    }

    /** Hashes [pin] with a fresh random salt into the storable string. */
    fun hash(pin: String, random: SecureRandom = SecureRandom()): String {
        val salt = ByteArray(SALT_BYTES).also { random.nextBytes(it) }
        val hash = pbkdf2(pin, salt, ITERATIONS)
        return "pbkdf2\$$ITERATIONS\$${b64(salt)}\$${b64(hash)}"
    }

    /** Constant-time check of [pin] against a [stored] hash; false on any malformed input. */
    fun verify(pin: String, stored: String?): Boolean {
        if (stored.isNullOrBlank()) return false
        val parts = stored.split("$")
        if (parts.size != 4 || parts[0] != "pbkdf2") return false
        val iterations = parts[1].toIntOrNull() ?: return false
        val salt = runCatching { unb64(parts[2]) }.getOrNull() ?: return false
        val expected = runCatching { unb64(parts[3]) }.getOrNull() ?: return false
        val actual = pbkdf2(pin, salt, iterations)
        return constantTimeEquals(expected, actual)
    }

    private fun pbkdf2(pin: String, salt: ByteArray, iterations: Int): ByteArray {
        val spec = PBEKeySpec(pin.toCharArray(), salt, iterations, KEY_BITS)
        return SecretKeyFactory.getInstance("PBKDF2WithHmacSHA256").generateSecret(spec).encoded
    }

    private fun constantTimeEquals(a: ByteArray, b: ByteArray): Boolean = MessageDigest.isEqual(a, b)

    private fun b64(bytes: ByteArray): String = java.util.Base64.getEncoder().encodeToString(bytes)
    private fun unb64(s: String): ByteArray = java.util.Base64.getDecoder().decode(s)

    private val WEAK_PINS = setOf("1234", "0000", "1111", "1212", "12345", "123456", "111111", "654321")
}
