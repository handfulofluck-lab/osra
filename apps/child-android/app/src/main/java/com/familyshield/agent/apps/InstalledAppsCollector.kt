package com.familyshield.agent.apps

import android.content.Context
import android.content.Intent
import android.content.pm.ApplicationInfo

/**
 * Reads the launcher-visible apps from PackageManager.
 *
 * Package visibility: `src/main/AndroidManifest.xml` already declares the `MAIN`/`LAUNCHER` intent
 * under `<queries>` (it is load-bearing for the HOME lookup since #165). That declaration is what
 * lets `queryIntentActivities` enumerate launchable apps on Android 11+ without the restricted
 * `QUERY_ALL_PACKAGES` permission — so the Play artefact keeps its narrow visibility (ADR-0021) and
 * this feature adds no permission.
 *
 * The agent's own package is skipped: it is not a candidate for an app rule, and a parent who
 * blocked it would disable the protection they are configuring.
 */
object InstalledAppsCollector {

    fun collect(context: Context): InstalledAppsReport {
        val pm = context.packageManager
        val launcherIntent = Intent(Intent.ACTION_MAIN).addCategory(Intent.CATEGORY_LAUNCHER)
        val resolved = runCatching { pm.queryIntentActivities(launcherIntent, 0) }.getOrDefault(emptyList())
        val candidates = resolved.mapNotNull { info ->
            val activity = info.activityInfo ?: return@mapNotNull null
            val packageId = activity.packageName ?: return@mapNotNull null
            if (packageId == context.packageName) return@mapNotNull null
            val appInfo: ApplicationInfo = activity.applicationInfo ?: return@mapNotNull null
            val label = runCatching { pm.getApplicationLabel(appInfo).toString() }.getOrDefault(packageId)
            val isSystem = (appInfo.flags and (ApplicationInfo.FLAG_SYSTEM or ApplicationInfo.FLAG_UPDATED_SYSTEM_APP)) != 0
            LauncherApp(packageId = packageId, label = label, isSystem = isSystem)
        }
        return InstalledAppsPolicy.build(candidates)
    }
}
