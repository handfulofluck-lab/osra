package com.familyshield.agent.setup

import java.net.URI
import java.net.URLDecoder
import java.net.URLEncoder

/**
 * Kotlin counterpart of the parent app's `PairQrPayload`
 * (`apps/parent-app/lib/features/pairing/pair_qr_payload.dart`). Format v1, `docs/SPEC.md` §14.4:
 *
 * ```text
 * osra://pair?v=1&code=482916&host=http%3A%2F%2F192.168.1.5%3A3000
 * ```
 *
 * The validation rules are deliberately identical to the Dart decoder, because a payload the parent
 * refuses to encode is not one the child may accept either:
 *
 * * the scheme is `osra`, the authority is `pair`, and the path is empty or `/`;
 * * `v` is exactly `1` — an unknown version is refused, never guessed;
 * * `code` is exactly six digits;
 * * `host` is an absolute `http(s)` URL with a non-empty host and no query or fragment.
 *
 * Pure JVM code (no `android.net.Uri`) so [PairQrPayloadTest] runs as a plain unit test.
 */
data class PairQrPayload(val code: String, val apiBaseUrl: String) {

    /** The digits a human can check without the whole code being read out or screenshotted. */
    fun maskedCode(): String = MASK + code.takeLast(2)

    /** The documented v1 string; kept in step with the Dart encoder for the round-trip test. */
    fun encode(): String {
        require(CODE_PATTERN.matches(code)) { "pairing code must be six digits" }
        require(isApiBaseUrl(apiBaseUrl)) { "pairing host must be an http(s) URL: $apiBaseUrl" }
        val encodedHost = URLEncoder.encode(apiBaseUrl, Charsets.UTF_8.name())
        return "$SCHEME://$AUTHORITY?v=$VERSION&code=$code&host=$encodedHost"
    }

    companion object {
        const val SCHEME = "osra"
        const val AUTHORITY = "pair"
        const val VERSION = "1"

        /** The masked prefix in [maskedCode]; a bullet, not a digit. */
        const val MASK = "••••"

        private val CODE_PATTERN = Regex("""\d{6}""")

        /**
         * Decodes [raw], throwing [PairQrFormatException] with a reason a person can act on.
         * There is no lenient path: a scanner that cannot name why a code is invalid must not
         * fall back to pairing with whatever it happened to read.
         */
        fun decode(raw: String): PairQrPayload {
            val uri = try {
                URI(raw)
            } catch (e: Exception) {
                throw PairQrFormatException("not an OSRA pairing code")
            }
            if (!SCHEME.equals(uri.scheme, ignoreCase = true) ||
                !AUTHORITY.equals(uri.host, ignoreCase = true) ||
                !(uri.rawPath.isNullOrEmpty() || uri.rawPath == "/")
            ) {
                throw PairQrFormatException("not an OSRA pairing code")
            }

            val params = parseQuery(uri.rawQuery)
            val version = params["v"]
            if (version != VERSION) {
                throw PairQrFormatException(
                    "unsupported pairing code version: ${version ?: "missing"}",
                )
            }
            val code = params["code"]
            if (code == null || !CODE_PATTERN.matches(code)) {
                throw PairQrFormatException("the pairing code is not six digits")
            }
            val host = params["host"]
            if (host == null || !isApiBaseUrl(host)) {
                throw PairQrFormatException("the server address in the QR code is not an http(s) URL")
            }
            return PairQrPayload(code = code, apiBaseUrl = host)
        }

        private fun parseQuery(rawQuery: String?): Map<String, String> {
            if (rawQuery.isNullOrEmpty()) return emptyMap()
            val result = linkedMapOf<String, String>()
            for (part in rawQuery.split("&")) {
                if (part.isEmpty()) continue
                val separator = part.indexOf('=')
                val rawKey = if (separator < 0) part else part.substring(0, separator)
                val rawValue = if (separator < 0) "" else part.substring(separator + 1)
                val key = try {
                    decodeComponent(rawKey)
                } catch (e: IllegalArgumentException) {
                    throw PairQrFormatException("the QR code has malformed percent-encoding")
                }
                val value = try {
                    decodeComponent(rawValue)
                } catch (e: IllegalArgumentException) {
                    throw PairQrFormatException("the QR code has malformed percent-encoding")
                }
                result[key] = value // Dart's Uri.queryParameters keeps the last duplicate
            }
            return result
        }

        /**
         * Percent-decodes a query component the way Dart's `Uri.queryParameters` does: `+` is a
         * literal plus, not a space. `URLDecoder` is the JDK's form decoder, so protect `+` first.
         */
        private fun decodeComponent(value: String): String =
            URLDecoder.decode(value.replace("+", "%2B"), Charsets.UTF_8.name())

        private fun isApiBaseUrl(value: String): Boolean {
            val uri = try {
                URI(value)
            } catch (e: Exception) {
                return false
            }
            return (uri.scheme.equals("http", ignoreCase = true) ||
                uri.scheme.equals("https", ignoreCase = true)) &&
                !uri.host.isNullOrEmpty() &&
                uri.rawQuery.isNullOrEmpty() &&
                uri.rawFragment.isNullOrEmpty()
        }
    }
}

/** A scanned string that cannot be used as a v1 pairing payload; [message] says why. */
class PairQrFormatException(message: String) : Exception(message)
