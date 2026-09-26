package com.familyshield.agent.network

import java.nio.charset.StandardCharsets
import javax.crypto.Mac
import javax.crypto.spec.SecretKeySpec
import okhttp3.Interceptor
import okhttp3.Response

/**
 * Adds `X-FamilyShield-Signature: HMAC-SHA256(body, secret)` to every request whose path contains
 * an `internal` segment (per spec §12.3). [secretProvider] returns the device HMAC secret, or null
 * to send unsigned (e.g. not yet provisioned).
 */
class SignatureInterceptor(
    private val secretProvider: () -> String?,
) : Interceptor {

    override fun intercept(chain: Interceptor.Chain): Response {
        val request = chain.request()
        if (!request.url.pathSegments.contains("internal")) return chain.proceed(request)
        val body = request.body ?: return chain.proceed(request)
        val secret = secretProvider() ?: return chain.proceed(request)
        val buffer = okio.Buffer()
        body.writeTo(buffer)
        val signature = hmacSha256Hex(secret, buffer.readByteArray())
        return chain.proceed(request.newBuilder().header(HEADER, signature).build())
    }

    companion object {
        const val HEADER: String = "X-FamilyShield-Signature"

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
