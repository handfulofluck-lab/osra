package com.familyshield.agent.receivers

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
 */
object BootStartPolicy {

    /** First API level where `ACCESS_BACKGROUND_LOCATION` is a runtime permission (Android 10). */
    private const val BACKGROUND_LOCATION_RUNTIME_FROM = 29

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
    ): Boolean {
        if (!hasFineLocation && !hasCoarseLocation) return false
        return apiLevel < BACKGROUND_LOCATION_RUNTIME_FROM || hasBackgroundLocation
    }
}
