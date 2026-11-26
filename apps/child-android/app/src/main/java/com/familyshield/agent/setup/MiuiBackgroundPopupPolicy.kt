package com.familyshield.agent.setup

import android.app.AppOpsManager
import android.content.Context
import android.content.Intent
import android.os.Build
import android.os.Process

/**
 * osra-security#78 & #1174: Xiaomi/Redmi/POCO (MIUI / HyperOS) enforces a separate background
 * pop-up permission (`MIUIOP 10021`, "Display pop-up windows while running in the background")
 * and lock-screen pop-up (`MIUIOP 10020`) in addition to AOSP `Settings.canDrawOverlays`.
 *
 * When `10021` is `ignore`, MIUI silently aborts background starts of `LockActivity`,
 * `BlockActivity`, and `TamperGuardTaskActivity`. Requiring `10021` (and `10020` when readable)
 * inside `GrantChecks.isGranted(OVERLAY)` on Xiaomi-family devices ensures setup cannot complete
 * and "Phone is protected" cannot fire until background pop-ups are allowed.
 */
object MiuiBackgroundPopupPolicy {

    /** MIUI AppOp for "Display pop-up windows while running in the background". */
    const val OP_BACKGROUND_START_ACTIVITY: Int = 10021

    /** MIUI AppOp for "Show on Lock screen". */
    const val OP_SHOW_WHEN_LOCKED: Int = 10020

    const val MODE_ALLOWED: Int = AppOpsManager.MODE_ALLOWED

    fun isXiaomiFamily(manufacturer: String?): Boolean {
        val m = manufacturer?.trim()?.lowercase() ?: return false
        return m.contains("xiaomi") || m.contains("redmi") || m.contains("poco")
    }

    /**
     * Pure decision (JVM-tested):
     * - Non-Xiaomi devices: always true (standard AOSP overlay suffices).
     * - Xiaomi / Redmi / POCO: `op10021Mode` must be [MODE_ALLOWED]; if `op10020Mode` is readable
     *   (non-null), it must also be [MODE_ALLOWED]. If `op10021Mode` could not be read at all
     *   (null on an unexpected non-MIUI ROM), fail open rather than permanently deadlocking setup.
     */
    fun isBackgroundPopupAllowed(
        manufacturer: String?,
        op10021Mode: Int?,
        op10020Mode: Int? = null,
    ): Boolean {
        if (!isXiaomiFamily(manufacturer)) return true
        if (op10021Mode != null && op10021Mode != MODE_ALLOWED) return false
        if (op10020Mode != null && op10020Mode != MODE_ALLOWED) return false
        return true
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

    fun isGranted(context: Context): Boolean {
        if (!isXiaomiFamily(Build.MANUFACTURER)) return true
        val op10021 = checkOpMode(context, OP_BACKGROUND_START_ACTIVITY)
        val op10020 = checkOpMode(context, OP_SHOW_WHEN_LOCKED)
        return isBackgroundPopupAllowed(Build.MANUFACTURER, op10021, op10020)
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
}
