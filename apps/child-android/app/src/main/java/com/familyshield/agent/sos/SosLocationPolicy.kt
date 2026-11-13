package com.familyshield.agent.sos

import java.time.Instant

/**
 * Issue #672: what a SOS alert tells the parent about **where**.
 *
 * The scenario (Flip4, 19:15:5xZ): SOS reached the parent's list in 5.2 s — inside the 10 s limit — but its
 * metadata held only `deviceId`, and the body named no place, while location was granted "all the time"
 * and a 13-minute-old fix was on the phone. A parent who gets an SOS needs "where" in the same breath.
 *
 * The keys are flat strings because that is how this alert's metadata already travels (`AlertDto.metadata`
 * is `Map<String, String>`; `app_blocked` sends `packageId`/`reason`, a tamper alert sends `type`/`layout`).
 * The API validates the same five keys (`services/api/src/lib/alertLocation.ts`) and drops an implausible
 * one, so a half-location never reaches the parent app; the app renders them as a sentence.
 *
 * **A missing fix is not an error.** An SOS a parent never receives because the phone could not answer
 * "where am I" would be worse than the bug this closes, so [metadata] returns an empty map and the alert
 * goes anyway.
 */
object SosLocationPolicy {

    /** Latitude in degrees, WGS-84. */
    const val KEY_LAT = "lat"

    /** Longitude in degrees, WGS-84. */
    const val KEY_LNG = "lng"

    /** Horizontal accuracy of the fix, metres. */
    const val KEY_ACCURACY_M = "accuracyM"

    /** When the platform took the fix, ISO-8601 UTC (`2026-11-13T19:11:02Z`). */
    const val KEY_TAKEN_AT = "takenAt"

    /** How old the fix was when the SOS was sent, whole seconds. */
    const val KEY_AGE_SECONDS = "ageSeconds"

    /** One platform fix, in the form the pure table consumes. */
    data class Fix(val lat: Double, val lng: Double, val accuracyM: Float, val takenAtMs: Long)

    /**
     * The metadata one SOS carries: the five keys for a fix that describes a real point, and an empty
     * map for anything else — absent, half, or outside the world. A fix that cannot be a place is not a
     * reason to withhold the SOS, which is why this never throws and never refuses the alert.
     */
    fun metadata(fix: Fix?, nowMs: Long): Map<String, String> {
        if (fix == null) return emptyMap()
        // A coordinate that cannot exist, or a fix with no time to age, is no location at all. Dropped
        // whole: a pin placed on one axis, or aged from 1970, is worse than a parent reading no place.
        if (!fix.lat.isFinite() || !fix.lng.isFinite()) return emptyMap()
        if (fix.lat < -90.0 || fix.lat > 90.0 || fix.lng < -180.0 || fix.lng > 180.0) return emptyMap()
        if (fix.takenAtMs <= 0L) return emptyMap()

        val out = linkedMapOf(
            KEY_LAT to fix.lat.toString(),
            KEY_LNG to fix.lng.toString(),
            KEY_TAKEN_AT to Instant.ofEpochMilli(fix.takenAtMs).toString(),
            // A clock step backwards must not print a negative age: "0 s ago" is the honest floor.
            KEY_AGE_SECONDS to ((nowMs - fix.takenAtMs).coerceAtLeast(0L) / 1000L).toString(),
        )
        // Accuracy is optional: a platform that did not report one leaves the key out rather than
        // claiming a precision it does not have.
        if (fix.accuracyM.isFinite() && fix.accuracyM >= 0f) out[KEY_ACCURACY_M] = fix.accuracyM.toString()
        return out
    }
}
