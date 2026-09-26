package com.familyshield.agent.network

import okhttp3.HttpUrl.Companion.toHttpUrl
import okhttp3.Interceptor
import okhttp3.Response

/**
 * Application-level interceptor that rewrites every request's scheme/host/port to the base URL
 * stored in AgentSettings (§14.2), so a tester-hosted backend works without rebuilding. Retrofit
 * is built against a placeholder base; this runs first in the chain.
 */
class DynamicBaseUrlInterceptor(
    private val baseUrlProvider: () -> String?,
) : Interceptor {

    override fun intercept(chain: Interceptor.Chain): Response {
        val raw = baseUrlProvider()
        if (raw.isNullOrBlank()) return chain.proceed(chain.request())
        // NOTE: unparseable stored URL falls through to the placeholder host rather than crashing.
        val base = runCatching { raw.toHttpUrl() }.getOrNull() ?: return chain.proceed(chain.request())

        val request = chain.request()
        val url = request.url.newBuilder()
            .scheme(base.scheme)
            .host(base.host)
            .port(base.port)
            .encodedPath(rewritePath(base.encodedPath, request.url.encodedPath))
            .build()
        return chain.proceed(request.newBuilder().url(url).build())
    }

    companion object {
        /**
         * Prepends a non-root base path (e.g. a tunneled /api prefix) to the request path.
         * Pure so it is unit-testable on the JVM. [basePath] comes from HttpUrl.encodedPath
         * (always at least "/"); [requestPath] always starts with "/".
         */
        internal fun rewritePath(basePath: String, requestPath: String): String {
            val prefix = basePath.trimEnd('/')
            if (prefix.isEmpty()) return requestPath
            return prefix + requestPath
        }
    }
}
