package com.familyshield.agent.security

/**
 * #828 (Karim, Flip4, 15 Nov): while a lock or pause is on, the notification shade still opens over the
 * lock overlay. Every notification is readable in full and WhatsApp's inline Reply works, so the child
 * keeps chatting while "locked".
 *
 * The accessibility service sees the shade's window event and collapses it with
 * `GLOBAL_ACTION_DISMISS_NOTIFICATION_SHADE` (API 31+). Collapsing is the narrow action: the phone app,
 * the emergency dialer and a ringing call are untouched — an incoming call is a full-screen intent, not
 * the shade — and nothing about the child's own notification data is read.
 *
 * Pure, so the JVM suite holds the cases: a lock, an unrelated window, an old API and a package that is
 * not systemui must all be no-ops.
 */
object ShadePolicy {
    /** Only systemui hosts the shade; Settings' "notification" screens are not it. */
    const val SHADE_PACKAGE = "com.android.systemui"

    /** Simple-name fragments across AOSP, Google and One UI: StatusBarWindowView, NotificationShadeWindowView, ShadeWindow. */
    private val SHADE_CLASSES = listOf("statusbar", "notificationshade", "shadewindow", "shade")

    /** `GLOBAL_ACTION_DISMISS_NOTIFICATION_SHADE` exists from API 31. */
    const val MIN_API = 31

    fun shouldCollapse(locked: Boolean, packageName: String?, className: String?, apiLevel: Int): Boolean {
        if (!locked) return false
        if (apiLevel < MIN_API) return false
        if (packageName != SHADE_PACKAGE) return false
        val name = className?.lowercase() ?: return false
        return SHADE_CLASSES.any { name.contains(it) }
    }
}
