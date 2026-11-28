package com.familyshield.agent.setup

import android.app.AppOpsManager
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.net.VpnService
import android.os.Build
import android.os.PowerManager
import android.os.Process
import android.provider.Settings
import androidx.core.app.NotificationManagerCompat
import androidx.core.content.ContextCompat
import com.familyshield.agent.security.AccessibilityServiceListPolicy
import com.familyshield.agent.security.DeviceAdminManager
import com.familyshield.agent.services.AccessibilityMonitorService
import com.familyshield.agent.vpn.VpnState

/**
 * Plan 1.6 — the Android half of [OnboardingPolicy]: asks the OS whether each grant is in place
 * (re-run on every resume, never cached) and builds the Settings intent that fixes it. Device admin
 * and the VPN consent return results through launchers in [PairingActivity], so their "fix" is a
 * null intent here and a button there.
 */
class GrantChecks(private val context: Context, private val deviceAdmin: DeviceAdminManager) {

    fun isGranted(grant: OnboardingPolicy.Grant): Boolean = when (grant) {
        OnboardingPolicy.Grant.ACCESSIBILITY -> accessibilityEnabled()
        OnboardingPolicy.Grant.USAGE_ACCESS -> usageAccessGranted()
        OnboardingPolicy.Grant.OVERLAY -> Settings.canDrawOverlays(context) && MiuiBackgroundPopupPolicy.isGranted(context)
        OnboardingPolicy.Grant.DEVICE_ADMIN -> deviceAdmin.isAdminActive()
        OnboardingPolicy.Grant.WEB_FILTER -> VpnService.prepare(context) == null && VpnState.isEnabled(context)
        OnboardingPolicy.Grant.LOCATION -> locationGranted()
        OnboardingPolicy.Grant.PRIVATE_DNS -> OnboardingPolicy.privateDnsOk(Settings.Global.getString(context.contentResolver, "private_dns_mode"))
        OnboardingPolicy.Grant.BATTERY -> context.getSystemService(PowerManager::class.java)?.isIgnoringBatteryOptimizations(context.packageName) ?: true
        OnboardingPolicy.Grant.USB_DEBUGGING -> OnboardingPolicy.usbDebuggingOff(
            runCatching { Settings.Global.getInt(context.contentResolver, Settings.Global.ADB_ENABLED) }.getOrNull(),
        )
        OnboardingPolicy.Grant.NOTIFICATION_LISTENER -> NotificationManagerCompat.getEnabledListenerPackages(context).contains(context.packageName)
    }

    /** The Settings screen that fixes [grant], or null when the fix is a launcher flow in the activity. */
    fun fixIntent(grant: OnboardingPolicy.Grant): Intent? {
        val pkg = Uri.parse("package:${context.packageName}")
        return when (grant) {
            OnboardingPolicy.Grant.ACCESSIBILITY -> {
                val choice = AccessibilitySettingsIntent.chooseAction(
                    resolvesDetails = context.packageManager.resolveActivity(
                        Intent(AccessibilitySettingsIntent.ACTION_DETAILS), 0,
                    ) != null,
                )
                Intent(choice.action).takeIf { choice.withComponent }?.putExtra(
                    Intent.EXTRA_COMPONENT_NAME,
                    ComponentName(context, AccessibilityMonitorService::class.java),
                ) ?: Intent(choice.action)
            }
            OnboardingPolicy.Grant.USAGE_ACCESS -> Intent(Settings.ACTION_USAGE_ACCESS_SETTINGS)
            OnboardingPolicy.Grant.OVERLAY -> if (!Settings.canDrawOverlays(context)) {
                Intent(Settings.ACTION_MANAGE_OVERLAY_PERMISSION, pkg)
            } else {
                MiuiBackgroundPopupPolicy.miuiPermEditorIntent(context)
            }
            OnboardingPolicy.Grant.DEVICE_ADMIN -> null
            OnboardingPolicy.Grant.WEB_FILTER -> null
            OnboardingPolicy.Grant.LOCATION -> null
            OnboardingPolicy.Grant.PRIVATE_DNS -> Intent(Settings.ACTION_WIRELESS_SETTINGS)
            OnboardingPolicy.Grant.BATTERY -> Intent(Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS, pkg)
            OnboardingPolicy.Grant.USB_DEBUGGING -> Intent(Settings.ACTION_APPLICATION_DEVELOPMENT_SETTINGS)
            OnboardingPolicy.Grant.NOTIFICATION_LISTENER -> Intent(Settings.ACTION_NOTIFICATION_LISTENER_SETTINGS)
        }.let { it?.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK) }
    }

    /** Opens OSRA's App info screen so the parent can grant "Allow restricted settings" (#1131). */
    fun appInfoIntent(): Intent = RestrictedSettingsPolicy.appInfoIntent(context.packageName)

    private fun accessibilityEnabled(): Boolean {
        val enabled = Settings.Secure.getString(context.contentResolver, Settings.Secure.ENABLED_ACCESSIBILITY_SERVICES)
        return RestrictedSettingsPolicy.isAccessibilityBoundAndEnabled(
            enabledServicesSetting = enabled,
            packageName = context.packageName,
            serviceClassName = AccessibilityMonitorService::class.java.name,
            isServiceRunning = AccessibilityMonitorService.isRunning,
        )
    }

    private fun usageAccessGranted(): Boolean {
        val ops = context.getSystemService(AppOpsManager::class.java) ?: return false
        val mode = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            ops.unsafeCheckOpNoThrow(AppOpsManager.OPSTR_GET_USAGE_STATS, Process.myUid(), context.packageName)
        } else {
            @Suppress("DEPRECATION")
            ops.checkOpNoThrow(AppOpsManager.OPSTR_GET_USAGE_STATS, Process.myUid(), context.packageName)
        }
        return mode == AppOpsManager.MODE_ALLOWED ||
            (mode == AppOpsManager.MODE_DEFAULT && context.checkCallingOrSelfPermission(android.Manifest.permission.PACKAGE_USAGE_STATS) == PackageManager.PERMISSION_GRANTED)
    }

    private fun locationGranted(): Boolean {
        val fine = ContextCompat.checkSelfPermission(context, android.Manifest.permission.ACCESS_FINE_LOCATION) == PackageManager.PERMISSION_GRANTED
        val coarse = ContextCompat.checkSelfPermission(context, android.Manifest.permission.ACCESS_COARSE_LOCATION) == PackageManager.PERMISSION_GRANTED
        if (!fine && !coarse) return false
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) return true
        return ContextCompat.checkSelfPermission(context, android.Manifest.permission.ACCESS_BACKGROUND_LOCATION) == PackageManager.PERMISSION_GRANTED
    }
}
