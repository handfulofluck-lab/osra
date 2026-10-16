package com.familyshield.agent.network

import java.nio.charset.StandardCharsets
import java.security.SecureRandom
import javax.crypto.Mac
import javax.crypto.spec.SecretKeySpec
import okhttp3.Interceptor
import okhttp3.Response

/**
 * Signs every request whose path contains an `internal` segment (spec §12.3) with the v2 internal
 * signing contract (ADR-0014):
 *
 *   X-FamilyShield-Timestamp: unix seconds
 *   X-FamilyShield-Nonce:     32 hex chars, unique per request
 *   X-FamilyShield-Signature: HMAC-SHA256(secret, "<timestamp>.<nonce>.<body>")
 *
 * The server rejects a request whose timestamp is more than 5 minutes off its clock, and a nonce it
 * has already seen for this device — so a captured request cannot be replayed. [secretProvider]
 * returns the device HMAC secret, or null to send unsigned (e.g. not yet provisioned).
 */
class SignatureInterceptor(
    private val secretProvider: () -> String?,
    private val clock: () -> Long = { System.currentTimeMillis() / 1000 },
    private val nonceProvider: () -> String = { newNonce() },
) : Interceptor {

    override fun intercept(chain: Interceptor.Chain): Response {
        val request = chain.request()
        if (!request.url.pathSegments.contains("internal")) return chain.proceed(request)
        val body = request.body ?: return chain.proceed(request)
        val secret = secretProvider() ?: return chain.proceed(request)
        val buffer = okio.Buffer()
        body.writeTo(buffer)
        val timestamp = clock().toString()
        val nonce = nonceProvider()
        val signature = hmacSha256Hex(secret, signingBytes(timestamp, nonce, buffer.readByteArray()))
        return chain.proceed(
            request.newBuilder()
                .header(HEADER, signature)
                .header(HEADER_TIMESTAMP, timestamp)
                .header(HEADER_NONCE, nonce)
                .build(),
        )
    }

    companion object {
        const val HEADER: String = "X-FamilyShield-Signature"
        const val HEADER_TIMESTAMP: String = "X-FamilyShield-Timestamp"
        const val HEADER_NONCE: String = "X-FamilyShield-Nonce"

        private val random = SecureRandom()

        /** The v2 signing string: `timestamp.nonce.` followed by the exact body bytes. */
        fun signingBytes(timestamp: String, nonce: String, body: ByteArray): ByteArray {
            val prefix = "$timestamp.$nonce.".toByteArray(StandardCharsets.UTF_8)
            return prefix + body
        }

        /** 16 random bytes as 32 lowercase hex chars. */
        fun newNonce(): String {
            val bytes = ByteArray(16)
            random.nextBytes(bytes)
            return bytes.joinToString("") { String.format("%02x", it) }
        }

        /** Returns the hex-encoded HMAC-SHA256 of [data] under [secret]. */
        fun hmacSha256Hex(secret: String, data: ByteArray): String {
            val mac = Mac.getInstance("HmacSHA256")
            mac.init(SecretKeySpec(secret.toByteArray(StandardCharsets.UTF_8), "HmacSHA256"))
            val digest = mac.doFinal(data)
            val sb = StringBuilder(digest.size * 2)
            for (b in digest) sb.append(String.format("%02x", b))
            return sb.toString()
        }
    }
}
