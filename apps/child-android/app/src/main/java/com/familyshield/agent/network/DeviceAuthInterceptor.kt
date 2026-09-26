package com.familyshield.agent.network

import okhttp3.Interceptor
import okhttp3.Response

/**
 * Adds `Authorization: Bearer <deviceToken>` when a device JWT has been provisioned.
 * [tokenProvider] returns null before enrollment, in which case requests go out unsigned.
 */
class DeviceAuthInterceptor(
    private val tokenProvider: () -> String?,
) : Interceptor {

    override fun intercept(chain: Interceptor.Chain): Response {
        val token = tokenProvider()
        val request = if (token.isNullOrBlank()) {
            chain.request()
        } else {
            chain.request().newBuilder().header("Authorization", "Bearer $token").build()
        }
        return chain.proceed(request)
    }
}
