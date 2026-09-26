package com.familyshield.agent.receivers

/**
 * Pure 1 h throttle shared by the periodic Feature #19/#20 agent alerts (accessibility-disabled,
 * VPN routing, package-replaced). Keys are per detection type so one alert type never suppresses
 * another. Kept Android-free so the throttle keying and window decision are JVM-testable.
 */
object AlertThrottlePolicy {

    /** Min delay between two alerts of the same detection type. */
    const val THROTTLE_WINDOW_MS: Long = 60 * 60_000L

    /** DataStore preferences-key prefix for per-type last-alert timestamps. */
    const val THROTTLE_KEY_PREFIX: String = "tamper_alert_ts_"

    /** DataStore key recording the last alert of [type]. */
    fun throttleKey(type: String): String = THROTTLE_KEY_PREFIX + type

    /**
     * True when an alert of some type should be raised. [lastAlertAtMs] is the persisted
     * timestamp under [throttleKey] for that type, null when never alerted.
     */
    fun shouldAlert(lastAlertAtMs: Long?, nowMs: Long): Boolean {
        val last = lastAlertAtMs ?: return true
        return nowMs - last >= THROTTLE_WINDOW_MS
    }
}
