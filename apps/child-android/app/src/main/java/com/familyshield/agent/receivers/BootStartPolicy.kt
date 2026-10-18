package com.familyshield.agent.receivers

import com.familyshield.agent.services.LocationStartPolicy

/**
 * Issue #128: what `BootReceiver` may start after `BOOT_COMPLETED`. Pure and JVM-tested — the same
 * pattern as [com.familyshield.agent.enforcement.LockEnforcementPolicy] — because the receiver
 * itself cannot be instantiated in a plain JVM test.
 *
 * The measured failure: `startForegroundService()` was called before location was granted,
 * `LocationService.startForegroundCompat()` refused to call `startForeground()`, `stopSelf()`
 * followed — and the system still raised
 * `android.app.ForegroundServiceDidNotStartInTimeException` in the receiver, killing the process.
 * `BOOT_COMPLETED` is a background context, so a location FGS started there needs the
 * background grant as well: on API 29+ `ACCESS_FINE_LOCATION`/`ACCESS_COARSE_LOCATION` alone is a
 * while-in-use grant, and Android 14+ rejects a location FGS created from the background without
 * `ACCESS_BACKGROUND_LOCATION`. This matches [com.familyshield.agent.setup.GrantChecks], which is
 * what onboarding shows the parent as "Location (allow all the time)".
 *
 * Issue #132 moved the rule itself to [LocationStartPolicy] so the accessibility-monitor and
 * `locate_now` start sites share it instead of growing a second copy. This name is kept for the
 * boot row and its tests; the implementation is the shared one.
 */
object BootStartPolicy {

    /**
     * Whether the receiver may request [com.familyshield.agent.services.LocationService].
     *
     * @param apiLevel `Build.VERSION.SDK_INT`, passed in so the rule is testable on the JVM.
     */
    fun shouldStartLocationService(
        hasFineLocation: Boolean,
        hasCoarseLocation: Boolean,
        hasBackgroundLocation: Boolean,
        apiLevel: Int,
    ): Boolean = LocationStartPolicy.shouldStart(
        hasFineLocation = hasFineLocation,
        hasCoarseLocation = hasCoarseLocation,
        hasBackgroundLocation = hasBackgroundLocation,
        apiLevel = apiLevel,
    )
}
