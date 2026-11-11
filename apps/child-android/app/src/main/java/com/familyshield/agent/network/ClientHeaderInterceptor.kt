package com.familyshield.agent.network

import okhttp3.Interceptor
import okhttp3.Response

/**
 * ADR-0034 decision 4: every request names the build, so the server can say "update".
 *
 * The value comes from [ClientHeader.value], which returns null when this build cannot be described
 * truthfully; a null sends **no header at all**, and the server treats that as a legacy client and serves
 * the request as it always has. That is deliberate: the header is a hint, not a control (A3), so losing it
 * costs the upgrade prompt, while sending a wrong build number would put a lie in front of the version gate.
 */
class ClientHeaderInterceptor(
    private val valueProvider: () -> String?,
) : Interceptor {

    override fun intercept(chain: Interceptor.Chain): Response {
        val value = valueProvider()
        val request = if (value.isNullOrBlank()) {
            chain.request()
        } else {
            chain.request().newBuilder().header(ClientHeader.NAME, value).build()
        }
        return chain.proceed(request)
    }
}
