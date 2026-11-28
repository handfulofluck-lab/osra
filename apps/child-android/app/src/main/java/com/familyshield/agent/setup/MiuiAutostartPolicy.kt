package com.familyshield.agent.setup

import android.app.AppOpsManager
import android.content.Context
import android.content.Intent
import android.os.Build
import android.os.PowerManager

/** Classification of Xiaomi/MIUI Autostart AppOp (`10008`). */
enum class MiuiAutostartState {
    /** Non-Xiaomi device, or `OP_AUTO_START` (`10008`) explicitly reports `MODE_ALLOWED`. */
    ALLOWED,

    /** `OP_AUTO_START` (`10008`) explicitly reports a non-allowed mode (never overridable by confirmation). */
    DENIED,

    /** Xiaomi-family device where `OP_AUTO_START` could not be read via AppOps reflection. */
    UNREADABLE,
}

/**
 * Xiaomi/Redmi/POCO (MIUI / HyperOS) Autostart requirement (osra-security#78).
 *
 * Without MIUI Autostart (`OP_AUTO_START = 10008`) and unrestricted battery, Xiaomi's system
 * cleaner blocks background process revival and leaves foreground and accessibility services
 * stopped after task cleanup. Requiring both inside [OnboardingPolicy.Grant.BATTERY] on Xiaomi-family
 * devices ensures onboarding does not mark protection complete until background revival is permitted.
 */
object MiuiAutostartPolicy {

    /** MIUI AppOp for Autostart (`OP_AUTO_START`). */
    const val OP_AUTO_START: Int = 10008

    const val MODE_ALLOWED: Int = AppOpsManager.MODE_ALLOWED

    private const val PREFS = "osra_miui_autostart_confirm_v1"
    private const val KEY_PARENT_CONFIRMED = "parent_confirmed"

    fun isXiaomiFamily(manufacturer: String?): Boolean =
        MiuiBackgroundPopupPolicy.isXiaomiFamily(manufacturer)

    /** Pure classifier (JVM-tested): readable denial always takes precedence over unreadable. */
    fun classifyState(manufacturer: String?, op10008Mode: Int?): MiuiAutostartState {
        if (!isXiaomiFamily(manufacturer)) return MiuiAutostartState.ALLOWED
        if (op10008Mode == null) return MiuiAutostartState.UNREADABLE
        return if (op10008Mode == MODE_ALLOWED) MiuiAutostartState.ALLOWED else MiuiAutostartState.DENIED
    }

    /**
     * Pure decision (JVM-tested):
     * - [MiuiAutostartState.ALLOWED] -> `true`.
     * - [MiuiAutostartState.DENIED] -> always `false` (parent confirmation cannot override a readable denial).
     * - [MiuiAutostartState.UNREADABLE] -> `parentConfirmed` (`false` by default).
     */
    fun isAutostartAllowed(
        manufacturer: String?,
        op10008Mode: Int?,
        parentConfirmed: Boolean = false,
    ): Boolean = when (classifyState(manufacturer, op10008Mode)) {
        MiuiAutostartState.ALLOWED -> true
        MiuiAutostartState.DENIED -> false
        MiuiAutostartState.UNREADABLE -> parentConfirmed
    }

    fun isParentConfirmed(context: Context): Boolean =
        prefs(context).getBoolean(KEY_PARENT_CONFIRMED, false)

    fun confirmByParent(context: Context) {
        prefs(context).edit().putBoolean(KEY_PARENT_CONFIRMED, true).apply()
    }

    fun clearParentConfirmation(context: Context) {
        prefs(context).edit().remove(KEY_PARENT_CONFIRMED).apply()
    }

    fun isGranted(context: Context): Boolean {
        if (!isXiaomiFamily(Build.MANUFACTURER)) return true
        val op10008 = MiuiBackgroundPopupPolicy.checkOpMode(context, OP_AUTO_START)
        return isAutostartAllowed(
            manufacturer = Build.MANUFACTURER,
            op10008Mode = op10008,
            parentConfirmed = isParentConfirmed(context),
        )
    }

    /**
     * True when the Xiaomi-family `BATTERY` onboarding step has already satisfied standard battery
     * optimization exemption, `OP_AUTO_START` cannot be read via reflection, and the parent has not
     * yet confirmed turning Autostart on.
     */
    fun needsParentConfirmation(context: Context): Boolean {
        if (!isXiaomiFamily(Build.MANUFACTURER)) return false
        val ignoringBattery = context.getSystemService(PowerManager::class.java)
            ?.isIgnoringBatteryOptimizations(context.packageName) ?: true
        if (!ignoringBattery) return false
        if (isParentConfirmed(context)) return false
        val op10008 = MiuiBackgroundPopupPolicy.checkOpMode(context, OP_AUTO_START)
        return classifyState(Build.MANUFACTURER, op10008) == MiuiAutostartState.UNREADABLE
    }

    /** Deep-link to MIUI's Autostart management screen, falling back to App info when absent. */
    fun autostartIntent(context: Context): Intent {
        val explicit = Intent().apply {
            setClassName(
                "com.miui.securitycenter",
                "com.miui.permcenter.autostart.AutoStartManagementActivity",
            )
            putExtra("extra_pkgname", context.packageName)
        }
        val canResolveExplicit = runCatching {
            context.packageManager.resolveActivity(explicit, 0) != null
        }.getOrDefault(false)
        if (canResolveExplicit) return explicit

        val actionIntent = Intent("miui.intent.action.OP_AUTO_START").apply {
            addCategory(Intent.CATEGORY_DEFAULT)
            putExtra("extra_pkgname", context.packageName)
        }
        val canResolveAction = runCatching {
            context.packageManager.resolveActivity(actionIntent, 0) != null
        }.getOrDefault(false)
        return if (canResolveAction) actionIntent else RestrictedSettingsPolicy.appInfoIntent(context.packageName)
    }

    private fun prefs(context: Context) =
        context.applicationContext.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
}
