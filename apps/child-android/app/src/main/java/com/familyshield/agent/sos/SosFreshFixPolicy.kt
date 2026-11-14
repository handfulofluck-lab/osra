package com.familyshield.agent.sos

/**
 * Issue #672 review (Fable, note 1): may the SOS screen ask for a fresh high-accuracy fix?
 *
 * `requestFreshFix()` starts [com.familyshield.agent.services.LocationService] with `ACTION_PING_NOW` — the
 * `locate_now` path without a command — from the resumed SOS activity, so the while-in-use location grant is
 * enough and `ACCESS_BACKGROUND_LOCATION` is not a precondition ([com.familyshield.agent.services.LocationStartPolicy]
 * is the rule for the *background* starts). What it must still refuse is the phone with no family:
 * `LocationStartPolicy` answers UNPAIRED first for every other start site (#472), and an unlinked phone has
 * no parent to show the ping to. The FGS would also put an ongoing location notification on a device nobody
 * manages, which is exactly what the unlink notice tells the family can be removed.
 *
 * Pure, so the JVM suite holds the table without an Android location client.
 */
object SosFreshFixPolicy {

    /**
     * A fresh fix is requested only when the phone is paired **and** holds a location grant. Both are
     * needed: without the grant the service declines and the start itself can kill the process (#128/#132);
     * without the pairing the fix has no reader.
     */
    fun shouldRequest(isPaired: Boolean, hasLocationPermission: Boolean): Boolean =
        isPaired && hasLocationPermission
}
