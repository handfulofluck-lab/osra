package com.familyshield.agent.receivers

/**
 * osra-security#8 F6: the Boot, PackageAdded and PackageReplaced receivers must stay exported to get the
 * system's broadcasts, so any app can address them with an explicit intent. Each one takes only the one action
 * it is for, and the two that tell the parent something confirm it with PackageManager first: a package that is
 * not installed, or was not installed just now, raises no install alert, and our own package must really have
 * been replaced just now for the "Agent updated" alert. Pure, so the JVM tests feed it the facts.
 */
object BroadcastGate {

    /** How recent an install or replace must be to match the broadcast that reports it. */
    const val FRESH_MS: Long = 10 * 60_000L

    /** A little clock slack the other way, so a broadcast stamped a moment ahead still counts. */
    const val SKEW_MS: Long = 60_000L

    /** What PackageManager says about a package; null when it is not installed. */
    data class PackageFacts(val firstInstallMs: Long, val lastUpdateMs: Long)

    fun accepts(expected: String, action: String?): Boolean = action != null && action == expected

    /** PACKAGE_ADDED (not a replace): the package is installed, and its first install is recent. */
    fun genuineInstall(facts: PackageFacts?, nowMs: Long): Boolean =
        facts != null && fresh(facts.firstInstallMs, nowMs)

    /** MY_PACKAGE_REPLACED: our own package's last update is recent. */
    fun genuineSelfReplace(own: PackageFacts?, nowMs: Long): Boolean =
        own != null && fresh(own.lastUpdateMs, nowMs)

    private fun fresh(atMs: Long, nowMs: Long): Boolean = atMs > 0 && nowMs - atMs in -SKEW_MS..FRESH_MS
}
