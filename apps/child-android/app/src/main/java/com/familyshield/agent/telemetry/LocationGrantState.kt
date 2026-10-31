package com.familyshield.agent.telemetry

import com.familyshield.agent.services.LocationStartPolicy

/**
 * Issue #221 (D1): the location grant the agent reports in POST /v1/devices/<id>/telemetry.
 *
 * The server cannot see the handset's grants. Without "allow all the time" background location the
 * agent's `LocationService` (and its 60-second poll) never starts (#155), so the only poll left is
 * WorkManager's 15-minute floor: a `locate_now` issued in the ten minutes before a tick used to
 * expire unseen. Reporting the state lets the server fail that command at the POST, with the same
 * reason vocabulary a refused in-process command already acks ([LocationStartPolicy]).
 *
 * The three wire values are the server contract (`services/api/src/lib/locationGrant.ts`):
 * `background`, `while_in_use` (fine/coarse only), `none`. Pre-Android-10 has no background runtime
 * permission and the policy starts from a background context, so fine/coarse is reported as
 * `background` there — the same rule, not a separate one.
 */
object LocationGrantState {
    const val BACKGROUND = "background"
    const val WHILE_IN_USE = "while_in_use"
    const val NONE = "none"

    /** Classifies raw grants exactly as [LocationStartPolicy] decides whether a background start is legal. */
    fun classify(
        hasFineLocation: Boolean,
        hasCoarseLocation: Boolean,
        hasBackgroundLocation: Boolean,
        apiLevel: Int,
    ): String = report(
        LocationStartPolicy.decide(
            // The link is not a grant: this classifies fine/coarse/background for telemetry, and
            // "unpaired" has its own reporting path there. See LocationStartPolicy.Decision.UNPAIRED.
            isPaired = true,
            hasFineLocation = hasFineLocation,
            hasCoarseLocation = hasCoarseLocation,
            hasBackgroundLocation = hasBackgroundLocation,
            apiLevel = apiLevel,
        ),
    )

    /** Maps the policy's decision to the telemetry value; [LocationStartPolicy.Decision.START] means a background start is allowed. */
    fun report(decision: LocationStartPolicy.Decision): String = when (decision) {
        LocationStartPolicy.Decision.START -> BACKGROUND
        LocationStartPolicy.Decision.MISSING_BACKGROUND_LOCATION -> WHILE_IN_USE
        LocationStartPolicy.Decision.MISSING_LOCATION_PERMISSION -> NONE
        // Unreachable through [classify], which asks the policy with `isPaired = true` because this
        // value describes a grant, not the link (#472). Kept explicit so a future decision cannot
        // fall into the wrong bucket silently.
        LocationStartPolicy.Decision.UNPAIRED -> NONE
    }
}
