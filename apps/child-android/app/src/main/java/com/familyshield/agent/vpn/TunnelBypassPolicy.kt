package com.familyshield.agent.vpn

/**
 * Issue #458: which packages leave the tunnel untested, and why.
 *
 * **The failure this answers.** While the `sinkhole_all` pause is up the tunnel takes the default
 * route and drops everything that lands in it — including `com.google.android.gms`. Once FCM's socket
 * drops it cannot reconnect through a tunnel that drops its packets, so a `resume_internet` does not
 * wake the phone by push and waits for the next poll, which is up to 15 minutes. A pause a parent
 * cannot lift quickly is worse than the pause itself.
 *
 * **The trade this makes, stated rather than hidden.** Excluding `com.google.android.gms` lets Play
 * services traffic through during a pause. That is accepted because it is not content a child can
 * browse with: the Play Store (`com.android.vending`) is *not* excluded and stays inside the
 * sinkhole, as does every app the parent did not always-allow.
 *
 * **Why it is a pure function.** The real tunnel is built by Android's `VpnService.Builder`, which a
 * JVM test cannot construct; the decision of *who* is excluded can still be pinned. `FilterVpnService`
 * applies exactly this list, in this order, and does no filtering of its own.
 */
object TunnelBypassPolicy {

    /** Google Play services: the FCM wake path. Not browsable content, so it may stay reachable. */
    const val FCM_PACKAGE: String = "com.google.android.gms"

    /**
     * The packages to pass to `addDisallowedApplication`, in the order they are added.
     *
     * @param sinkholeAll true in `MODE_SINKHOLE_ALL` (pause-internet), false for the DNS-only tunnel.
     *   The DNS tunnel routes a single address, so nothing else needs excluding and the exclusion list
     *   stays as small as it can be.
     * @param selfPackage the agent's own package: its API calls must never land in its own sinkhole,
     *   or the poll that would lift the pause is dropped by the pause.
     * @param alwaysAllowedApps the family's always-allowed apps (Feature #9/#11), which the parent has
     *   already decided must keep working.
     *
     * Duplicates are removed, order preserved, so `selfPackage` is always first and the result is
     * stable for a row to assert.
     */
    fun excludedPackages(
        sinkholeAll: Boolean,
        selfPackage: String,
        alwaysAllowedApps: List<String>,
    ): List<String> {
        val packages = LinkedHashSet<String>()
        packages += selfPackage
        if (sinkholeAll) packages += FCM_PACKAGE
        packages += alwaysAllowedApps
        // An empty or blank name is not a package: the builder would throw and, more importantly, a
        // row would read as a success. Drop them before they reach it.
        return packages.filter { it.isNotBlank() }
    }
}
