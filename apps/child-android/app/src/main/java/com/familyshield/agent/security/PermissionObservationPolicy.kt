package com.familyshield.agent.security

/**
 * Issue #225: permission-off tamper alerts are edges, not levels. "Off now" alone is not tamper — a
 * fresh install spends setup with accessibility and the overlay permission off, so a level-triggered
 * check pages the parent about a protection they never had. The alert is raised only when the
 * permission was previously observed granted and is revoked now.
 *
 * One rule is shared by every permission whose grant has an alert site (accessibility, overlay), so
 * a new site cannot accidentally re-introduce the level trigger. Pure and Android-free so the
 * decision is JVM-testable; the caller owns the persisted observation.
 */
object PermissionObservationPolicy {

    /**
     * True only on a recorded granted -> revoked edge. [wasGranted] is the last persisted
     * observation, `null` when the permission has never been seen granted (first check after
     * install or re-pair); a first observation that it is off is therefore silent.
     */
    fun shouldAlertOnObservation(wasGranted: Boolean?, isGrantedNow: Boolean): Boolean =
        wasGranted == true && !isGrantedNow
}
