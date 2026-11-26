package com.familyshield.agent.setup

import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.provider.Settings
import com.familyshield.agent.security.AccessibilityServiceListPolicy
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.launch

/**
 * Issue #1131: Android 13+ (API 33) blocks sideloaded apps from enabling Accessibility until the
 * parent taps the service once (triggering Android's "Restricted setting" dialog) and then opens
 * App info -> overflow menu -> "Allow restricted settings".
 *
 * Pure policy for when onboarding shows that guide and when the Accessibility step is truly done
 * (only when the service is actually **bound**, not merely listed in Settings.Secure).
 */
object RestrictedSettingsPolicy {

    /** Android 13 (Tiramisu, API 33) introduced Restricted Settings for non-store installs. */
    const val MIN_SDK_INT: Int = 33

    private const val FSI: Char = '\u2068'
    private const val PDI: Char = '\u2069'

    /** Recognized app stores whose installs Android does not mark as restricted. */
    private val STORE_INSTALLERS: Set<String> = setOf(
        "com.android.vending",
        "com.amazon.venezia",
        "com.sec.android.app.samsungapps",
        "com.huawei.appmarket",
        "com.xiaomi.mipicks",
        "com.xiaomi.market",
        "com.oppo.market",
        "com.heytap.market",
        "com.vivo.appstore",
    )

    fun isStoreInstaller(installerPackageName: String?): Boolean {
        val normalized = installerPackageName?.trim()?.lowercase().orEmpty()
        return normalized.isNotEmpty() && normalized in STORE_INSTALLERS
    }

    /**
     * Show the "Allow restricted settings" guide only on Android 13+ for non-store installs.
     * Play flavor installs and store-installed builds never see this guide.
     */
    fun requiresGuide(
        sdkInt: Int,
        installerPackageName: String?,
        isPlayBuild: Boolean = false,
    ): Boolean {
        if (isPlayBuild) return false
        if (sdkInt < MIN_SDK_INT) return false
        return !isStoreInstaller(installerPackageName)
    }

    /**
     * Issue #1131 acceptance #3: the Accessibility step completes only when the service is both
     * listed in `Settings.Secure.ENABLED_ACCESSIBILITY_SERVICES` **and** actively bound in this
     * process ([isServiceRunning], set from `AccessibilityMonitorService.onServiceConnected`).
     */
    fun isAccessibilityBoundAndEnabled(
        enabledServicesSetting: String?,
        packageName: String,
        serviceClassName: String,
        isServiceRunning: Boolean,
    ): Boolean {
        if (!isServiceRunning || enabledServicesSetting.isNullOrBlank()) return false
        return AccessibilityServiceListPolicy.isEnabled(enabledServicesSetting, packageName, serviceClassName)
    }

    /**
     * Wrap the live service label in Unicode FSI...PDI (`\u2068...\u2069`) so English/mixed labels
     * render cleanly inside Arabic RTL sentences (Arabic Language Bureau, #1131 comment 7168407917).
     */
    fun isolateServiceLabel(label: String): String = "$FSI${label.trim()}$PDI"

    /** Reads the installer package name without throwing on older or restricted devices. */
    fun installerPackageName(context: Context): String? = runCatching {
        val pm = context.packageManager
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            pm.getInstallSourceInfo(context.packageName).installingPackageName
        } else {
            @Suppress("DEPRECATION")
            pm.getInstallerPackageName(context.packageName)
        }
    }.getOrNull()

    /** Opens OSRA's own App info page so the parent can tap ⋮ -> Allow restricted settings. */
    fun appInfoIntent(packageName: String): Intent =
        Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS, Uri.fromParts("package", packageName, null))
            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
}

/**
 * Issue #1131 review: observes [runningState] while the Accessibility onboarding step (or checklist
 * with Accessibility ungranted) is visible in the foreground, so a parent who returns from Settings
 * before Android finishes binding the accessibility service advances automatically the moment the
 * bind arrives instead of stalling on a stale resume snapshot.
 *
 * Stops observing immediately on [stop] (called when the screen changes or the activity pauses).
 */
class AccessibilityBindObserver(
    private val runningState: StateFlow<Boolean>,
    private val isAccessibilityGranted: () -> Boolean,
    private val onBoundWhileVisible: () -> Unit,
) {
    private var observeJob: Job? = null

    val isObserving: Boolean
        get() = observeJob?.isActive == true

    fun start(scope: CoroutineScope) {
        stop()
        if (runningState.value && isAccessibilityGranted()) {
            onBoundWhileVisible()
            return
        }
        observeJob = scope.launch {
            runningState.first { running -> running && isAccessibilityGranted() }
            observeJob = null
            onBoundWhileVisible()
        }
    }

    fun stop() {
        observeJob?.cancel()
        observeJob = null
    }
}
