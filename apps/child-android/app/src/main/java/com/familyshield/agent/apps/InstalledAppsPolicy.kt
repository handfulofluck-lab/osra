package com.familyshield.agent.apps

import java.security.MessageDigest

/**
 * Roadmap 3.4: one launchable app as the OS describes it. [launchable] is true only when the entry
 * came from a launcher-intent resolution (`ACTION_MAIN` + `CATEGORY_LAUNCHER`); the policy drops
 * anything else so a future collector that enumerates every installed package cannot leak apps the
 * child cannot open.
 */
data class LauncherApp(
    val packageId: String,
    val label: String,
    val isSystem: Boolean,
    val launchable: Boolean = true,
)

/** The deduped, sorted, capped list that is uploaded; [truncated] says the cap was reached. */
data class InstalledAppsReport(
    val apps: List<LauncherApp>,
    val truncated: Boolean,
)

/**
 * Pure list builder, so the JVM tests can pin the rules without an Android device:
 *  - only launcher-visible apps,
 *  - one row per package (first occurrence wins; a package can expose several launcher activities),
 *  - a non-blank trimmed label, falling back to the package id,
 *  - labels capped at [MAX_LABEL] characters,
 *  - sorted by label then package id (stable across PackageManager ordering),
 *  - at most [MAX_APPS] rows, with [InstalledAppsReport.truncated] set when the cap bites.
 *
 * No usage, launch counts, screen-on time or icons: this is "what is installed and visible to the
 * launcher", the minimum the parent needs to build an app rule.
 */
object InstalledAppsPolicy {
    const val MAX_APPS = 500
    const val MAX_LABEL = 100

    fun build(candidates: Iterable<LauncherApp>): InstalledAppsReport {
        val byPackage = LinkedHashMap<String, LauncherApp>()
        for (candidate in candidates) {
            if (!candidate.launchable) continue
            val packageId = candidate.packageId.trim()
            if (packageId.isEmpty() || byPackage.containsKey(packageId)) continue
            val label = candidate.label.trim().ifEmpty { packageId }.take(MAX_LABEL)
            byPackage[packageId] = candidate.copy(
                packageId = packageId,
                label = label,
                launchable = true,
            )
        }
        val sorted = byPackage.values.sortedWith(
            compareBy({ it.label.lowercase() }, { it.packageId }),
        )
        return InstalledAppsReport(apps = sorted.take(MAX_APPS), truncated = sorted.size > MAX_APPS)
    }

    /** Stable SHA-256 over the built list, so the reporter uploads only when something changed. */
    fun fingerprint(apps: List<LauncherApp>): String {
        val digest = MessageDigest.getInstance("SHA-256")
        for (app in apps) {
            val line = "${app.packageId}\u0000${app.label}\u0000${if (app.isSystem) "1" else "0"}\n"
            digest.update(line.toByteArray(Charsets.UTF_8))
        }
        return digest.digest().joinToString("") { "%02x".format(it) }
    }
}
