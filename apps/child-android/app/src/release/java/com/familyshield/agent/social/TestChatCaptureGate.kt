package com.familyshield.agent.social

import android.content.Context

/**
 * Release build stub: the debug-only test-chat capture filter is never compiled into Release APKs.
 * Release capture behaviour is unchanged.
 */
object TestChatCaptureGate {
    fun allows(
        @Suppress("UNUSED_PARAMETER") context: Context,
        @Suppress("UNUSED_PARAMETER") appKey: String,
        @Suppress("UNUSED_PARAMETER") contact: String?,
    ): Boolean = true
}
