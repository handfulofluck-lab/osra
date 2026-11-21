package com.familyshield.agent.social

import android.content.Context
import java.io.File
import java.nio.charset.StandardCharsets
import java.security.MessageDigest
import java.util.Locale

/**
 * Debug-only on-device capture gate for staging test phones.
 *
 * Compiled into `debug` builds only (`src/release` supplies an unconditional no-op stub, verified
 * by CI's Release DEX strings check). When `files/osra_test_chat_filter.conf` is absent on the
 * device, capture behaves normally. When present (configured locally via `adb shell run-as`), only
 * notifications/screen captures whose contact matches the locally stored salted SHA-256 hash are
 * allowed through to `SocialScanQueue.enqueue`; all other chats are dropped on-device before
 * queueing, and malformed config files fail closed.
 *
 * Neither the contact, message text, salt, nor hash is ever logged.
 */
object TestChatCaptureGate {
    const val CONFIG_FILE_NAME: String = "osra_test_chat_filter.conf"

    fun allows(
        context: Context,
        @Suppress("UNUSED_PARAMETER") appKey: String,
        contact: String?,
    ): Boolean {
        val file = File(context.filesDir, CONFIG_FILE_NAME)
        if (!file.exists()) return true
        val raw = runCatching { file.readText(StandardCharsets.UTF_8) }.getOrNull() ?: return false
        return TestChatCaptureFilter.allows(raw, contact)
    }
}

/** Pure JVM filter logic for [TestChatCaptureGate] so unit tests cover every branch without Robolectric. */
object TestChatCaptureFilter {
    private val HEX_64 = Regex("^[0-9a-fA-F]{64}$")

    /** Normalizes a contact label before hashing: trims surrounding whitespace and folds ASCII/Unicode case. */
    fun normalizeContact(contact: String): String = contact.trim().lowercase(Locale.ROOT)

    /** Computes lowercase hex SHA-256 over `"<salt>:<normalizedContact>"` in UTF-8. */
    fun computeSaltedSha256Hex(salt: String, contact: String): String {
        val digest = sha256Bytes(salt, contact)
        val sb = StringBuilder(digest.size * 2)
        for (b in digest) sb.append(String.format(Locale.ROOT, "%02x", b))
        return sb.toString()
    }

    /**
     * Evaluates whether [contact] may be enqueued under [configText].
     *
     * - `configText == null`: filter is not configured -> returns `true`.
     * - `configText != null`: filter is active and fails closed (`false`) if `salt` is blank,
     *   `sha256` is missing or not 64 hex chars, or [contact] is null/blank or does not match
     *   in constant time.
     */
    fun allows(configText: String?, contact: String?): Boolean {
        if (configText == null) return true
        val parsed = parseConfig(configText) ?: return false
        val candidate = contact?.takeIf { it.isNotBlank() } ?: return false
        val actual = sha256Bytes(parsed.salt, candidate)
        return MessageDigest.isEqual(actual, parsed.expectedDigest)
    }

    private data class Config(val salt: String, val expectedDigest: ByteArray)

    private fun parseConfig(text: String): Config? {
        var salt: String? = null
        var hex: String? = null
        for (rawLine in text.lineSequence()) {
            val line = rawLine.trim()
            if (line.isEmpty() || line.startsWith("#")) continue
            val eq = line.indexOf('=')
            if (eq <= 0) return null
            val key = line.substring(0, eq).trim()
            val value = line.substring(eq + 1).trim()
            when (key) {
                "salt" -> salt = value
                "sha256" -> hex = value
                else -> return null
            }
        }
        val validSalt = salt?.takeIf { it.isNotBlank() } ?: return null
        val validHex = hex?.takeIf { HEX_64.matches(it) } ?: return null
        return Config(validSalt, hexToBytes(validHex))
    }

    private fun sha256Bytes(salt: String, contact: String): ByteArray {
        val payload = "$salt:${normalizeContact(contact)}".toByteArray(StandardCharsets.UTF_8)
        return MessageDigest.getInstance("SHA-256").digest(payload)
    }

    private fun hexToBytes(hex: String): ByteArray {
        val out = ByteArray(hex.length / 2)
        for (i in out.indices) {
            val hi = Character.digit(hex[i * 2], 16)
            val lo = Character.digit(hex[i * 2 + 1], 16)
            out[i] = ((hi shl 4) or lo).toByte()
        }
        return out
    }
}
