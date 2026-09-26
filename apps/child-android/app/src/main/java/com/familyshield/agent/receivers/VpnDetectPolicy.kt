package com.familyshield.agent.receivers

import android.net.NetworkCapabilities

/**
 * Pure Feature #20 decision: does a transport set mean the device's traffic is VPN-routed?
 * TRANSPORT_VPN is mirrored as a literal so the decision stays Android-free and JVM-testable
 * (it equals NetworkCapabilities.TRANSPORT_VPN).
 * // NOTE: local-VPN apps (some parental-control/antivirus/DNS filters run a loopback VPNService)
 * also set TRANSPORT_VPN, so a true result is a circumvention *signal* the parent judges, not
 * proof — hence the warning severity and empty metadata.
 */
object VpnDetectPolicy {

    /** Detection type; doubles as the per-type throttle key segment. */
    const val TYPE: String = "vpn"

    /** Mirror of NetworkCapabilities.TRANSPORT_VPN (kept as a literal, see file docstring). */
    const val TRANSPORT_VPN: Int = 4

    /** True when the collected transport types include [TRANSPORT_VPN]. */
    fun hasVpnTransport(transports: IntArray?): Boolean =
        transports != null && transports.any { it == TRANSPORT_VPN }

    /** Framework wrapper over the active network's capabilities (not unit-tested — android.jar). */
    fun hasVpnTransport(caps: NetworkCapabilities?): Boolean =
        caps != null && caps.hasTransport(NetworkCapabilities.TRANSPORT_VPN)
}
