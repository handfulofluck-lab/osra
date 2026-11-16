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

    fun shouldCollapse(
        locked: Boolean,
        packageName: String?,
        className: String?,
        apiLevel: Int,
        callRinging: Boolean = false,
    ): Boolean {
        if (!locked) return false
        if (apiLevel < MIN_API) return false
        // #828 (UI/UX Bureau): with the screen on, an incoming call is a heads-up in systemui. Collapsing
        // it would hide Answer. Only the ringing phase is exempt (Fable's review): during a placed or
        // answered call the shade is locked again, so a call cannot be used to browse notifications.
        if (callRinging) return false
        if (packageName != SHADE_PACKAGE) return false
        // Kimi's review: some OEM builds report a system window with a null class. With the systemui
        // package already narrow, a null class is treated as the shade — a guard that silently switches
        // itself off for an unnamed window is a bypass with no trace. Named systemui windows that are not
        // the shade (the volume dialog) are still excluded by the list.
        val name = className?.lowercase() ?: return true
        return SHADE_CLASSES.any { name.contains(it) }
    }
}
