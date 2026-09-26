package com.familyshield.agent.receivers

/**
 * Pure Feature #8 install-approval policy: decides whether a PACKAGE_ADDED event should raise an
 * install_request alert (skip self/replaces/blank packages, 24 h per-package throttle). Kept
 * Android-free so the decision and throttle keying are unit-testable on the JVM.
 */
object InstallAlertPolicy {

    /** Min delay between install_request alerts for the same package. */
    const val THROTTLE_WINDOW_MS: Long = 24 * 60 * 60_000L

    /** DataStore preferences-key prefix for per-package last-alert timestamps. */
    const val THROTTLE_KEY_PREFIX: String = "install_alert_ts_"

    /** DataStore key recording the last install_request alert for [packageId]. */
    fun throttleKey(packageId: String): String = THROTTLE_KEY_PREFIX + packageId

    /**
     * True when an install_request alert should be raised for [packageId].
     * [lastAlertAtMs] is the persisted timestamp under [throttleKey], null when never alerted.
     */
    fun shouldAlert(
        packageId: String,
        replacing: Boolean,
        selfPackage: String,
        lastAlertAtMs: Long?,
        nowMs: Long,
    ): Boolean {
        if (packageId.isBlank()) return false
        if (packageId == selfPackage) return false
        if (replacing) return false
        val last = lastAlertAtMs ?: return true
        return nowMs - last >= THROTTLE_WINDOW_MS
    }
}
