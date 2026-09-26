package com.familyshield.agent.social

/**
 * Monitored social/chat apps (Features #2/#17): maps a foreground package name to the app key used
 * in rule socialMonitoring flags, scan payloads and server-side vault entries. Pure JVM object.
 */
object MonitoredApps {

    /** App key for [packageId], or null when the package is not monitored. */
    fun appKeyFor(packageId: String): String? = when (packageId) {
        "com.whatsapp", "com.whatsapp.w4b" -> "whatsapp" // w4b = WhatsApp Business
        "com.instagram.android" -> "instagram"
        "com.zhiliaoapp.musically", "com.ss.android.ugc.trill" -> "tiktok" // global + China variants
        "com.snapchat.android" -> "snapchat"
        "com.twitter.android", "com.x.android" -> "twitter"
        "com.discord" -> "discord"
        "com.roblox.client" -> "roblox"
        "jp.naver.line.android" -> "line"
        else -> null
    }
}
