package com.familyshield.agent.enforcement

import android.Manifest
import android.app.ActivityManager
import android.app.admin.DevicePolicyManager
import android.content.Context
import android.content.pm.PackageManager
import android.util.Log
import androidx.core.content.ContextCompat
import com.familyshield.agent.apps.InstalledAppsCollector
import com.familyshield.agent.commands.LockActivity
import com.familyshield.agent.data.RuleRepository
import com.familyshield.agent.services.AccessibilityMonitorService

/**
 * Android adapter for [LockForceClosePolicy] (#1183 after-test follow-up).
 *
 * Called ONLY from `CommandDispatcher.lock()` (never from `pause()` or `pauseInternet()`), and
 * completely no-op while [LockForceCloseFlags.enabled] is `false`.
 */
object LockAppCloser {

    private const val TAG = "LockAppCloser"

    fun closeForLock(
        context: Context,
        rules: RuleRepository,
        devicePolicyManager: DevicePolicyManager,
    ): Map<String, String> {
        if (!LockForceCloseFlags.enabled) return emptyMap()

        // Pause non-always-allowed media sessions immediately if accessibility is bound.
        AccessibilityMonitorService.onLockActivated()

        val hasKillPerm = ContextCompat.checkSelfPermission(
            context,
            Manifest.permission.KILL_BACKGROUND_PROCESSES,
        ) == PackageManager.PERMISSION_GRANTED

        var killedCount = 0
        if (hasKillPerm) {
            val facts = AndroidPackageFacts(context)
            val alwaysAllowed = rules.cachedRules()?.alwaysAllowedApps?.toSet().orEmpty()
            val installed = runCatching {
                InstalledAppsCollector.collect(context).apps.map { it.packageId }
            }.getOrDefault(emptyList())
            val plan = LockForceClosePolicy.plan(
                enabled = true,
                mode = LockActivity.MODE_LOCKED,
                installedPackages = installed,
                ownPackage = context.packageName,
                alwaysAllowedPackages = alwaysAllowed,
                facts = facts,
            )
            if (plan.shouldExecute && plan.targetPackages.isNotEmpty()) {
                val am = context.getSystemService(ActivityManager::class.java)
                if (am != null) {
                    for (pkg in plan.targetPackages) {
                        runCatching { am.killBackgroundProcesses(pkg) }
                            .onSuccess { killedCount += 1 }
                            .onFailure { Log.w(TAG, "killBackgroundProcesses failed for $pkg", it) }
                    }
                }
            }
        }

        val isDeviceOwner = runCatching {
            devicePolicyManager.isDeviceOwnerApp(context.packageName)
        }.getOrDefault(false)

        return LockForceClosePolicy.ackDetailAdditions(
            enabled = true,
            mode = LockActivity.MODE_LOCKED,
            hasKillPermission = hasKillPerm,
            killedCount = killedCount,
            isDeviceOwner = isDeviceOwner,
            deviceOwnerSignedOut = false,
        )
    }
}
