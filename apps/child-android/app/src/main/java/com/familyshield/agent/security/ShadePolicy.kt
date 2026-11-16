package com.familyshield.agent.security

/**
 * #828 (Karim, Flip4, 15 Nov; re-shaped after Antigravity's Android 14 run and Fable's ruling):
 * while a lock or pause is on, the notification shade must not be usable.
 *
 * **Collapse by default inside systemui.** The class name cannot identify the shade: on Android 14 the
 * window event reports `android.widget.FrameLayout`, and One UI may report something else tomorrow. A
 * positive list of shade names therefore keeps failing open, silently — which is what the device run
 * measured. So any `TYPE_WINDOW_STATE_CHANGED` from `com.android.systemui` while locked sends the dismiss
 * action, unless a short non-shade list names the window. That failure mode is acceptable because of
 * what the action costs: `GLOBAL_ACTION_DISMISS_NOTIFICATION_SHADE` only closes the shade — measured with
 * the power menu focused, the collapse left it open and untouched. A false match is a no-op; a missed
 * match loses the whole guard.
 *
 * The exclusion list is tidiness, not safety. Nothing may depend on it being complete.
 *
 * Pure, so the JVM suite holds the measured cases: FrameLayout, null, the two dialog classes, another
 * package, the API floor, and the call exemption.
 */
object ShadePolicy {
    /** Only systemui hosts the shade; Settings' "notification" screens are not it. */
    const val SHADE_PACKAGE = "com.android.systemui"

    /** Measured on Android 14 and named so a future OEM window is a one-line addition, not a redesign. */
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
        // #828: a ringing incoming call's heads-up is not the shade, and hiding Answer would be the one
        // collateral damage that matters. The exemption is the ringing phase only (Fable), and it is
        // provisional until the device row says whether the collapse hides the pop-up at all.
        if (callRinging) return false
        if (packageName != SHADE_PACKAGE) return false
        val name = className?.lowercase() ?: return true
        return NON_SHADE_CLASSES.none { name.contains(it) }
    }
}
