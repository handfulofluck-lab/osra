package com.familyshield.agent.security

/**
 * #828 / osra-security#43 / osra-security#33: while a lock or pause is on, the notification shade
 * must not stay open over the lock screen.
 *
 * Collapses by default inside `com.android.systemui`: on Android 14 / One UI, top-edge shade pulls
 * report `android.widget.FrameLayout` or `null`, so a positive allowlist of shade class names fails
 * open. `GLOBAL_ACTION_DISMISS_NOTIFICATION_SHADE` only closes an expanded shade, while named
 * non-shade systemui windows (volume panel, power menu, biometric prompt, keyguard bouncer) stay
 * excluded while focused and clear as soon as focus leaves `com.android.systemui`.
 */
object ShadePolicy {
    const val SHADE_PACKAGE = "com.android.systemui"

    private val NON_SHADE_CLASSES = listOf(
        "volumedialog",
        "globalactions",
        "actionsdialog",
        "biometric",
        "keyguard",
    )

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
        if (callRinging) return false
        if (packageName != SHADE_PACKAGE) return false
        val name = className?.lowercase() ?: return true
        return NON_SHADE_CLASSES.none { name.contains(it) }
    }

    fun shouldCollapseOnContentChange(
        locked: Boolean,
        packageName: String?,
        lastKnownClass: String?,
        apiLevel: Int,
        callRinging: Boolean,
    ): Boolean = shouldCollapse(locked, packageName, lastKnownClass, apiLevel, callRinging)

    /**
     * Tracks the active `systemui` window class for content-change events, clearing any stale dialog
     * exclusion (`VolumeDialog`, `Keyguard`, etc.) when focus moves to another package or an unnamed
     * `systemui` window opens.
     */
    fun nextSystemUiClass(current: String?, eventPkg: String, eventClass: String?): String? =
        if (eventPkg == SHADE_PACKAGE) eventClass else null

    fun shouldRecheck(locked: Boolean, callRinging: Boolean): Boolean = locked && !callRinging
}
