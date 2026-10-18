package com.familyshield.agent.services

/**
 * Issue #132, the follow-up to #128: the one rule every background start of [LocationService] goes
 * through. #128 found the rule for `BOOT_COMPLETED` (`BootStartPolicy`, which now delegates here);
 * the accessibility monitor and `locate_now` still asked only for a fine/coarse grant and could
 * request a location foreground service the app is not allowed to hold.
 *
 * Why background location is required: `startForegroundService()` obliges the service to reach
 * `startForeground()`. `LocationService` declines when the location permission is missing, stops
 * itself without ever starting foreground — and the system then raises
 * `android.app.ForegroundServiceDidNotStartInTimeException`, killing the process. On API 29+
 * fine/coarse alone is a while-in-use grant; Android 14+ rejects a location FGS created from the
 * background without `ACCESS_BACKGROUND_LOCATION`. A service cannot fix this by refusing later: the
 * caller must not request it at all. This is the same definition of "Location (allow all the time)"
 * that onboarding shows the parent ([com.familyshield.agent.setup.GrantChecks]).
 *
 * The call sites read the three grants themselves (`ContextCompat.checkSelfPermission`) and pass the
 * booleans in, so the rule stays pure and JVM-tested; `LocationServiceStartSitesTest` pins the set of
 * call sites that must come through here.
 */
object LocationStartPolicy {

    /** First API level where `ACCESS_BACKGROUND_LOCATION` is a runtime permission (Android 10). */
    private const val BACKGROUND_LOCATION_RUNTIME_FROM = 29

    /**
     * The outcome of the rule. [reason] is the machine-readable contract a refused `locate_now`
     * reports in its `failed` command ack (`POST /v1/devices/:id/commands/:commandId/ack`), so the
     * strings are stable: a reviewer and the parent app read them from the command history.
     */
    enum class Decision(val reason: String?) {
        START(null),
        MISSING_LOCATION_PERMISSION("location_permission_missing"),
        MISSING_BACKGROUND_LOCATION("background_location_missing"),
    }

    /**
     * @param apiLevel `Build.VERSION.SDK_INT`, passed in so the rule is testable on the JVM.
     */
    fun decide(
        hasFineLocation: Boolean,
        hasCoarseLocation: Boolean,
        hasBackgroundLocation: Boolean,
        apiLevel: Int,
    ): Decision {
        if (!hasFineLocation && !hasCoarseLocation) return Decision.MISSING_LOCATION_PERMISSION
        if (apiLevel >= BACKGROUND_LOCATION_RUNTIME_FROM && !hasBackgroundLocation) {
            return Decision.MISSING_BACKGROUND_LOCATION
        }
        return Decision.START
    }

    /** Whether [LocationService] may be requested from a background context. */
    fun shouldStart(
        hasFineLocation: Boolean,
        hasCoarseLocation: Boolean,
        hasBackgroundLocation: Boolean,
        apiLevel: Int,
    ): Boolean = decide(hasFineLocation, hasCoarseLocation, hasBackgroundLocation, apiLevel) == Decision.START
}
