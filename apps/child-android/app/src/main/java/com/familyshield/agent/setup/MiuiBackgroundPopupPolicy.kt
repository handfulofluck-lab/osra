package com.familyshield.agent.setup

import android.app.AppOpsManager
import android.content.Context
import android.content.Intent
import android.os.Build
import android.os.Process
import android.provider.Settings

/** Classification of Xiaomi/MIUI background pop-up ops (`10021` and `10020`). */
enum class MiuiPopupState {
    /** Not a Xiaomi-family device, or `10021` (and readable `10020`) are explicitly allowed. */
    ALLOWED,
    /** OS explicitly reports `10021` or `10020` is not allowed (never overridable by confirmation). */
    DENIED,
    /** Xiaomi-family device where `10021` could not be read via AppOps reflection (#1235). */
    UNREADABLE,
}

/**
 * osra-security#78, #1174, & #1235: Xiaomi/Redmi/POCO (MIUI / HyperOS) enforces a separate
 * background pop-up permission (`MIUIOP 10021`, "Display pop-up windows while running in the
 * background") and lock-screen pop-up (`MIUIOP 10020`) in addition to AOSP
 * `Settings.canDrawOverlays`.
 *
 * When `10021` is `ignore`, MIUI silently aborts background starts of `LockActivity`,
 * `BlockActivity`, and `TamperGuardTaskActivity`. Requiring `10021` (and `10020` when readable)
 * inside `GrantChecks.isGranted(OVERLAY)` on Xiaomi-family devices ensures setup cannot complete
 * and "Phone is protected" cannot fire until background pop-ups are allowed.
 *
 * Issue #1235: when `10021` cannot be read (`null`, e.g. blocked reflection on a MIUI/HyperOS
 * build), it must **never** silently count as granted. It classifies as [MiuiPopupState.UNREADABLE],
 * stays incomplete (and listed in the parent's single `setup_incomplete:<deviceId>` notice), and
 * presents a guided parent-confirmation step in onboarding so setup neither fails open nor
 * deadlocks. A readable [MiuiPopupState.DENIED] is never overridable by parent confirmation.
 */
object MiuiBackgroundPopupPolicy {

    /** MIUI AppOp for "Display pop-up windows while running in the background". */
    const val OP_BACKGROUND_START_ACTIVITY: Int = 10021

    /** MIUI AppOp for "Show on Lock screen". */
    const val OP_SHOW_WHEN_LOCKED: Int = 10020

    const val MODE_ALLOWED: Int = AppOpsManager.MODE_ALLOWED

    private const val PREFS = "osra_miui_popup_confirm_v1"
    private const val KEY_PARENT_CONFIRMED = "parent_confirmed"

    fun isXiaomiFamily(manufacturer: String?): Boolean {
        val m = manufacturer?.trim()?.lowercase() ?: return false
        return m.contains("xiaomi") || m.contains("redmi") || m.contains("poco")
    }

    /** Pure state classifier (JVM-tested): every readable denial takes precedence over unreadable. */
    fun classifyState(
        manufacturer: String?,
        op10021Mode: Int?,
        op10020Mode: Int? = null,
    ): MiuiPopupState {
        if (!isXiaomiFamily(manufacturer)) return MiuiPopupState.ALLOWED
        if (op10021Mode != null && op10021Mode != MODE_ALLOWED) return MiuiPopupState.DENIED
        if (op10020Mode != null && op10020Mode != MODE_ALLOWED) return MiuiPopupState.DENIED
        if (op10021Mode == null) return MiuiPopupState.UNREADABLE
        return MiuiPopupState.ALLOWED
    }

    /**
     * Pure decision (JVM-tested):
     * - [MiuiPopupState.ALLOWED] -> `true`.
     * - [MiuiPopupState.DENIED] -> always `false` (parent confirmation cannot override a readable denial).
     * - [MiuiPopupState.UNREADABLE] -> `parentConfirmed` (`false` by default; never silently granted).
     */
    fun isBackgroundPopupAllowed(
        manufacturer: String?,
        op10021Mode: Int?,
        op10020Mode: Int? = null,
        parentConfirmed: Boolean = false,
    ): Boolean = when (classifyState(manufacturer, op10021Mode, op10020Mode)) {
        MiuiPopupState.ALLOWED -> true
        MiuiPopupState.DENIED -> false
        MiuiPopupState.UNREADABLE -> parentConfirmed
    }

    /** Reads MIUI hidden AppOps via `AppOpsManager.checkOpNoThrow(int, int, String)`. */
    fun checkOpMode(context: Context, opCode: Int): Int? = runCatching {
        val ops = context.getSystemService(AppOpsManager::class.java) ?: return@runCatching null
        val method = AppOpsManager::class.java.getMethod(
            "checkOpNoThrow",
            Int::class.javaPrimitiveType,
            Int::class.javaPrimitiveType,
            String::class.java,
        )
        method.invoke(ops, opCode, Process.myUid(), context.packageName) as? Int
    }.getOrNull()

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
        val op10021 = checkOpMode(context, OP_BACKGROUND_START_ACTIVITY)
        val op10020 = checkOpMode(context, OP_SHOW_WHEN_LOCKED)
        return isBackgroundPopupAllowed(
            manufacturer = Build.MANUFACTURER,
            op10021Mode = op10021,
            op10020Mode = op10020,
            parentConfirmed = isParentConfirmed(context),
        )
    }

    /** Issue #1236: honest capability wire state for `grants.miui_popup` (`granted` / `missing` / `confirmed_unverified` / `not_applicable`). */
    fun wireGrantState(context: Context): String {
        if (!isXiaomiFamily(Build.MANUFACTURER)) {
            return com.familyshield.agent.capabilities.CapabilitiesPolicy.NOT_APPLICABLE
        }
        val op10021 = checkOpMode(context, OP_BACKGROUND_START_ACTIVITY)
        val op10020 = checkOpMode(context, OP_SHOW_WHEN_LOCKED)
        return MiuiLaunchBackstopPolicy.miuiPopupWireState(
            manufacturer = Build.MANUFACTURER,
            op10021Mode = op10021,
            op10020Mode = op10020,
            parentConfirmed = isParentConfirmed(context),
        )
    }

    /**
     * Issue #1235: true when the onboarding OVERLAY step should offer the parent-confirmation
     * button (Xiaomi-family phone, AOSP overlay already granted, MIUI op 10021 unreadable, and
     * parent has not confirmed yet).
     */
    fun needsParentConfirmation(context: Context): Boolean {
        if (!isXiaomiFamily(Build.MANUFACTURER)) return false
        if (!Settings.canDrawOverlays(context)) return false
        if (isParentConfirmed(context)) return false
        val op10021 = checkOpMode(context, OP_BACKGROUND_START_ACTIVITY)
        val op10020 = checkOpMode(context, OP_SHOW_WHEN_LOCKED)
        return classifyState(Build.MANUFACTURER, op10021, op10020) == MiuiPopupState.UNREADABLE
    }

    /** Deep-link to MIUI's Other permissions editor for OSRA, falling back to App info if absent. */
    fun miuiPermEditorIntent(context: Context): Intent {
        val miui = Intent("miui.intent.action.APP_PERM_EDITOR").apply {
            setClassName(
                "com.miui.securitycenter",
                "com.miui.permcenter.permissions.PermissionsEditorActivity",
            )
            putExtra("extra_pkgname", context.packageName)
        }
        val canResolve = runCatching {
            context.packageManager.resolveActivity(miui, 0) != null
        }.getOrDefault(false)
        if (canResolve) return miui

        val genericMiui = Intent("miui.intent.action.APP_PERM_EDITOR").apply {
            putExtra("extra_pkgname", context.packageName)
        }
        val canResolveGeneric = runCatching {
            context.packageManager.resolveActivity(genericMiui, 0) != null
        }.getOrDefault(false)
        return if (canResolveGeneric) genericMiui else RestrictedSettingsPolicy.appInfoIntent(context.packageName)
    }

    private fun prefs(context: Context) =
        context.applicationContext.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
}
