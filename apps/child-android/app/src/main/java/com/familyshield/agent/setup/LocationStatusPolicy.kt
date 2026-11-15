package com.familyshield.agent.setup

import androidx.annotation.StringRes
import com.familyshield.agent.R
import com.familyshield.agent.services.LocationStartPolicy

/**
 * Issue #221 D3: what the pairing status screen is allowed to claim about location.
 *
 * The screen used to show "✓ Location tracking: Active" whenever a fine/coarse grant existed and the
 * service was running. On Android 10+ that is a **while-in-use** grant: the service may hold a
 * foreground location session, but it cannot be started from the background, so the 15-minute
 * WorkManager poll and `locate_now` fail with `background_location_missing` (issue #132's rule). The
 * parent was told location was active and then got a Locate that expired.
 *
 * [LocationStartPolicy] already decides whether a background start is allowed; this policy turns that
 * decision plus the service state into the one line the screen shows, so the tick cannot appear
 * without the "allow all the time" grant. Pure and Android-free, so the rule is JVM-testable.
 */
enum class LocationStatus {
    /** No fine/coarse grant at all: nothing can be tracked until the parent grants location. */
    MISSING_PERMISSION,

    /** While-in-use only: the screen must ask for "allow all the time", not claim Active. */
    MISSING_BACKGROUND,

    /** Background grant present but the foreground service is not running: actionable. */
    SERVICE_STOPPED,

    /** Background grant present and the service running: the only state that may show a tick. */
    ACTIVE,
}

object LocationStatusPolicy {

    /**
     * Issue #472: the pair state is deliberately not an input here. This screen only renders for a
     * paired device, and "unpaired" is not a location status — inventing one would put a dead line
     * on a screen nobody can reach. The start decision still asks the link first
     * ([LocationStartPolicy.decide]); the two answer different questions.
     */
    fun classify(
        hasFineLocation: Boolean,
        hasCoarseLocation: Boolean,
        hasBackgroundLocation: Boolean,
        apiLevel: Int,
        serviceRunning: Boolean,
    ): LocationStatus {
        val decision = LocationStartPolicy.decide(
            isPaired = true,
            hasFineLocation = hasFineLocation,
            hasCoarseLocation = hasCoarseLocation,
            hasBackgroundLocation = hasBackgroundLocation,
            apiLevel = apiLevel,
        )
        return when (decision) {
            LocationStartPolicy.Decision.MISSING_LOCATION_PERMISSION -> LocationStatus.MISSING_PERMISSION
            LocationStartPolicy.Decision.MISSING_BACKGROUND_LOCATION -> LocationStatus.MISSING_BACKGROUND
            LocationStartPolicy.Decision.START ->
                if (serviceRunning) LocationStatus.ACTIVE else LocationStatus.SERVICE_STOPPED
            LocationStartPolicy.Decision.UNPAIRED -> LocationStatus.MISSING_PERMISSION
        }
    }

    /** The line the status screen shows. Only [LocationStatus.ACTIVE] carries a tick. */
    fun line(status: LocationStatus): String = "\n" + when (status) {
        LocationStatus.MISSING_PERMISSION ->
            "⚠️ Location permission is required for live GPS tracking and geofence alerts."
        LocationStatus.MISSING_BACKGROUND ->
            "⚠️ Location: needs \"Allow all the time\" — without it Locate and geofence alerts " +
                "cannot reach this phone while the app is closed."
        LocationStatus.SERVICE_STOPPED -> "⚠️ Location service is not running."
        LocationStatus.ACTIVE -> "✓ Location tracking: Active"
    }

    /** The same line as a resource, for a screen that must render it in the phone's language (#709). */
    @StringRes
    fun lineRes(status: LocationStatus): Int = when (status) {
        LocationStatus.MISSING_PERMISSION -> R.string.location_status_missing_permission
        LocationStatus.MISSING_BACKGROUND -> R.string.location_status_missing_background
        LocationStatus.SERVICE_STOPPED -> R.string.location_status_service_stopped
        LocationStatus.ACTIVE -> R.string.location_status_active
    }

    /** The button that fixes [status], or null when there is nothing to fix. */
    fun actionLabel(status: LocationStatus): String? = when (status) {
        LocationStatus.MISSING_PERMISSION -> "Grant location permission"
        LocationStatus.MISSING_BACKGROUND -> "Allow location all the time"
        LocationStatus.SERVICE_STOPPED -> "Start location service"
        LocationStatus.ACTIVE -> null
    }

    /** The same button label as a resource (#709). */
    @StringRes
    fun actionRes(status: LocationStatus): Int? = when (status) {
        LocationStatus.MISSING_PERMISSION -> R.string.location_action_grant
        LocationStatus.MISSING_BACKGROUND -> R.string.location_action_allow_all_time
        LocationStatus.SERVICE_STOPPED -> R.string.location_action_start
        LocationStatus.ACTIVE -> null
    }

    /** True when the screen may show the green tick. Pinned by [LocationStatusPolicyTest]. */
    fun showsActiveTick(status: LocationStatus): Boolean = status == LocationStatus.ACTIVE
}
