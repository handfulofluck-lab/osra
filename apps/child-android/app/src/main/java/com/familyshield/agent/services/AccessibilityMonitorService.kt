package com.familyshield.agent.services

import android.Manifest
import android.accessibilityservice.AccessibilityService
import android.content.BroadcastReceiver
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.PackageManager
import android.os.Build
import android.util.Log
import android.view.accessibility.AccessibilityEvent
import androidx.core.content.ContextCompat
import com.familyshield.agent.data.AgentSettings
import com.familyshield.agent.data.ConsentState
import com.familyshield.agent.data.RuleRepository
import com.familyshield.agent.enforcement.AndroidPackageFacts
import com.familyshield.agent.enforcement.AppBlocker
import com.familyshield.agent.enforcement.LockEnforcementPolicy
import com.familyshield.agent.enforcement.LockState
import com.familyshield.agent.security.ParentPinStore
import com.familyshield.agent.security.TamperAlertWorker
import com.familyshield.agent.security.TamperGuardActivity
import com.familyshield.agent.security.TamperScreen
import com.familyshield.agent.security.TamperScreenPolicy
import com.familyshield.agent.security.TamperState
import com.familyshield.agent.social.SocialCapture
import com.familyshield.agent.telemetry.UsageReporter
import android.view.accessibility.AccessibilityNodeInfo
import dagger.hilt.android.AndroidEntryPoint
import javax.inject.Inject

@AndroidEntryPoint
class AccessibilityMonitorService : AccessibilityService() {
    @Inject lateinit var rules: RuleRepository
    @Inject lateinit var blocker: AppBlocker
    @Inject lateinit var usage: UsageReporter
    @Inject lateinit var social: SocialCapture
    @Inject lateinit var settings: AgentSettings
    @Inject lateinit var consentState: ConsentState
    @Inject lateinit var pinStore: ParentPinStore

    private var lastLocationCheckMs = 0L
    private var lastGuardMs = 0L

    /** Issue #132: log a refused start once per reason, not once per 60 s accessibility event. */
    private var loggedStartDecision: LocationStartPolicy.Decision? = null

    private val packageFacts by lazy { AndroidPackageFacts(this) }

    /** Issue #83 review F1: the dialer/system flags are cached for the hot path, so refresh on package changes. */
    private val packageChangeReceiver = object : BroadcastReceiver() {
        override fun onReceive(context: android.content.Context?, intent: Intent?) = packageFacts.refresh()
    }

    override fun onServiceConnected() {
        super.onServiceConnected()
        val filter = IntentFilter().apply {
            addAction(Intent.ACTION_PACKAGE_ADDED)
            addAction(Intent.ACTION_PACKAGE_REPLACED)
            addAction(Intent.ACTION_PACKAGE_REMOVED)
            addDataScheme("package")
        }
        runCatching { registerReceiver(packageChangeReceiver, filter) }
    }

    override fun onDestroy() {
        runCatching { unregisterReceiver(packageChangeReceiver) }
        super.onDestroy()
    }

    override fun onAccessibilityEvent(event: AccessibilityEvent?) {
        val pkg = event?.packageName?.toString() ?: return
        if (pkg == packageName) return
        ensureLocationServiceRunning()
        // ADR-0010 §3: the protection guard runs even while consent is paused — a paused agent is
        // still an installed one, and the parent must still hear about an uninstall attempt.
        guardProtectionScreens(event, pkg)
        enforceLockState(pkg)
        // ADR-0008 §3: consent withdrawn — the service keeps polling (to learn about a re-grant) but
        // records, captures and enforces nothing.
        if (consentState.isPaused()) return
        usage.recordForeground(pkg, System.currentTimeMillis())
        // Feature #2/#17: social/chat text capture for monitored apps (no-op elsewhere).
        social.onAccessibilityEvent(event)
        when (rules.evaluate(pkg)) {
            RuleRepository.Decision.BLOCK -> blocker.showBlockScreen(pkg)
            RuleRepository.Decision.TIME_LIMIT_REACHED -> blocker.showTimeLimitScreen(pkg)
            RuleRepository.Decision.ALLOW -> Unit
        }
    }

    /**
     * Issue #132: starts `LocationService` only when [LocationStartPolicy] says the app may hold a
     * location foreground service. The accessibility service runs in the background even while the
     * screen is on, so fine/coarse alone (a while-in-use grant) is not enough on Android 10+:
     * requesting the FGS anyway is the #128 failure in a different call site. A refusal is logged
     * with its reason and retried on the next 60 s tick — revocation or a re-grant changes the
     * answer without a restart.
     */
    private fun ensureLocationServiceRunning() {
        val now = System.currentTimeMillis()
        if (now - lastLocationCheckMs < 60_000L) return
        lastLocationCheckMs = now

        val decision = locationStartDecision(
            isServiceRunning = LocationService.isServiceRunning,
            paired = settings.deviceTokenSync() != null,
            hasFineLocation = granted(Manifest.permission.ACCESS_FINE_LOCATION),
            hasCoarseLocation = granted(Manifest.permission.ACCESS_COARSE_LOCATION),
            hasBackgroundLocation = granted(Manifest.permission.ACCESS_BACKGROUND_LOCATION),
            apiLevel = Build.VERSION.SDK_INT,
        ) ?: return
        if (decision != LocationStartPolicy.Decision.START) {
            if (loggedStartDecision != decision) {
                loggedStartDecision = decision
                Log.i(
                    TAG,
                    "not starting LocationService: ${decision.reason} — the app needs fine or coarse location " +
                        "and, on Android 10+, \"Location (allow all the time)\" (#132)",
                )
            }
            return
        }
        loggedStartDecision = null
        runCatching {
            ContextCompat.startForegroundService(this, Intent(this, LocationService::class.java))
        }.onFailure { Log.w(TAG, "the OS refused to start LocationService", it) }
    }

    private fun granted(permission: String): Boolean =
        ContextCompat.checkSelfPermission(this, permission) == PackageManager.PERMISSION_GRANTED

    /**
     * ADR-0010 §3: when the foreground window is the OS screen that would strip protection
     * (deactivate admin / uninstall / app-info for this package), step in front of it with the
     * parent-PIN gate and tell the parent. Cheap by construction: only window-change events from
     * system packages are inspected, texts are read once, and a 1.5-s debounce stops the gate from
     * being launched twice for the same screen.
     */
    private fun guardProtectionScreens(event: AccessibilityEvent, pkg: String) {
        if (event.eventType != AccessibilityEvent.TYPE_WINDOW_STATE_CHANGED &&
            event.eventType != AccessibilityEvent.TYPE_WINDOW_CONTENT_CHANGED
        ) return
        if (!settings.isPairedSync()) return
        val now = System.currentTimeMillis()
        if (now - lastGuardMs < 1_500L) return
        val root = rootInActiveWindow ?: return
        val texts = ArrayList<CharSequence?>(64)
        collectTexts(root, texts, 0)
        val screen = TamperScreenPolicy.classify(
            packageName = pkg,
            texts = texts,
            agentLabel = getString(com.familyshield.agent.R.string.app_name),
            adminLabel = getString(com.familyshield.agent.R.string.device_admin_label),
            agentPackage = packageName,
        )
        if (screen == TamperScreen.PRIVATE_DNS && !com.familyshield.agent.vpn.VpnState.isEnabled(this)) return // no filter to bypass yet
        if (!TamperScreenPolicy.shouldGuard(screen, pinStore.isConfigured(), TamperState.graceUntil(this), now)) return
        lastGuardMs = now
        performGlobalAction(GLOBAL_ACTION_BACK)
        startActivity(
            Intent(this, TamperGuardActivity::class.java)
                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP)
                .putExtra(TamperGuardActivity.EXTRA_REASON, TamperGuardActivity.REASON_SETTINGS),
        )
        TamperAlertWorker.enqueue(this, TamperAlertWorker.TYPE_GUARD_TRIGGERED, "Screen: ${screen.name.lowercase()} in $pkg")
    }

    private var lastReraiseMs = 0L

    /**
     * Plan 1.3: a parent's lock/pause survives a swipe from Recents, a Home press and a reboot because
     * the overlay is re-raised the moment any other window is in front while [LockState] is active
     * (phone calls and the system UI excepted, see [LockEnforcementPolicy]).
     */
    private fun enforceLockState(pkg: String) {
        val mode = LockState.mode(this)
        if (!LockEnforcementPolicy.shouldReraise(mode, pkg, packageName, packageFacts)) return
        val now = System.currentTimeMillis()
        if (now - lastReraiseMs < LockEnforcementPolicy.RERAISE_DEBOUNCE_MS) return
        lastReraiseMs = now
        startActivity(
            Intent(this, com.familyshield.agent.commands.LockActivity::class.java)
                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_REORDER_TO_FRONT)
                .putExtra(com.familyshield.agent.commands.LockActivity.EXTRA_MODE, mode),
        )
    }

    private fun collectTexts(node: AccessibilityNodeInfo, out: MutableList<CharSequence?>, depth: Int) {
        if (depth > 12 || out.size > 200) return
        node.text?.let { out.add(it) }
        node.contentDescription?.let { out.add(it) }
        for (i in 0 until node.childCount) {
            val child = node.getChild(i) ?: continue
            collectTexts(child, out, depth + 1)
        }
    }

    override fun onInterrupt() = Unit

    companion object {
        private const val TAG = "AccessibilityMonitor"

        /**
         * Issue #132: [ensureLocationServiceRunning]'s decision, pure so the JVM suite holds it in
         * the `BootStartPolicyTest` style (an [AccessibilityService] cannot be instantiated in a
         * plain JVM test). `null` means there is nothing to start: the service is already running,
         * or the device is not paired and a foreground service would upload nothing.
         */
        internal fun locationStartDecision(
            isServiceRunning: Boolean,
            paired: Boolean,
            hasFineLocation: Boolean,
            hasCoarseLocation: Boolean,
            hasBackgroundLocation: Boolean,
            apiLevel: Int,
        ): LocationStartPolicy.Decision? = when {
            isServiceRunning || !paired -> null
            else -> LocationStartPolicy.decide(
                hasFineLocation = hasFineLocation,
                hasCoarseLocation = hasCoarseLocation,
                hasBackgroundLocation = hasBackgroundLocation,
                apiLevel = apiLevel,
            )
        }
    }
}
