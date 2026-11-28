package com.familyshield.agent.setup

import android.os.Build
import android.provider.Settings

/**
 * #1287 finding 2: the Accessibility step opened Android's general Accessibility list, so the parent had to find
 * "Downloaded apps" and then OSRA on their own. On Android 13+ `ACTION_ACCESSIBILITY_DETAILS_SETTINGS` goes
 * straight to our own service's switch.
 *
 * Only the *choice* lives here, as plain data: the JVM unit suite has no `Intent` (the android.jar stub throws),
 * and the behaviour worth a row is "which screen, on which API level, when an OEM skin does not implement the
 * details activity". [GrantChecks] turns the choice into an Intent.
 */
object AccessibilitySettingsIntent {

    /**
     * `Settings.ACTION_ACCESSIBILITY_DETAILS_SETTINGS` by value: the constant is missing from the SDK stub this
     * app compiles against, while the activity itself has existed since API 26.
     */
    const val ACTION_DETAILS: String = "android.settings.ACCESSIBILITY_DETAILS_SETTINGS"

    /** What to open, and whether the OSRA service component travels with it. */
    data class Choice(val action: String, val withComponent: Boolean)

    /**
     * The details screen when the platform has it (API 33+) *and* something on this device resolves it; the
     * general list otherwise. The resolvability check is the OEM-skin guard: MIUI/HyperOS and some OnePlus builds
     * ship Settings without the details activity, and an unresolvable intent would strand the parent with a dead
     * button.
     */
    fun chooseAction(sdkInt: Int = Build.VERSION.SDK_INT, resolvesDetails: Boolean): Choice =
        if (sdkInt >= Build.VERSION_CODES.TIRAMISU && resolvesDetails) {
            Choice(ACTION_DETAILS, withComponent = true)
        } else {
            Choice(Settings.ACTION_ACCESSIBILITY_SETTINGS, withComponent = false)
        }
}
