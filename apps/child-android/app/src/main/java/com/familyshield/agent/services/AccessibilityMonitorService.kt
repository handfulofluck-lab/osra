package com.familyshield.agent.services

import android.Manifest
import android.accessibilityservice.AccessibilityService
import android.content.BroadcastReceiver
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.PackageManager
import android.os.Build
import android.os.SystemClock
import android.util.Log
import android.view.accessibility.AccessibilityEvent
import android.view.accessibility.AccessibilityNodeInfo
import android.view.accessibility.AccessibilityWindowInfo
import androidx.core.content.ContextCompat
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import com.familyshield.agent.data.AgentSettings
import com.familyshield.agent.data.ConsentState
import com.familyshield.agent.data.RuleRepository
import com.familyshield.agent.data.WindowReason
import com.familyshield.agent.enforcement.AppBlocker
import com.familyshield.agent.enforcement.BlockRaisePolicy
import com.familyshield.agent.enforcement.BypassAlertFloor
import com.familyshield.agent.enforcement.EssentialPackages
import com.familyshield.agent.enforcement.FilterRecoveryPolicy
import com.familyshield.agent.enforcement.IncomingRingWindow
import com.familyshield.agent.enforcement.LockEnforcementPolicy
import com.familyshield.agent.enforcement.LockState
import com.familyshield.agent.enforcement.OverlayRetryBudget
import com.familyshield.agent.enforcement.PackageFacts
import com.familyshield.agent.enforcement.RetryDecision
import com.familyshield.agent.enforcement.VisibleBlockStep
import com.familyshield.agent.enforcement.VisibleWindow
import com.familyshield.agent.enforcement.WindowBounds
import com.familyshield.agent.commands.RingActivity
import com.familyshield.agent.commands.RingReentryPolicy
import com.familyshield.agent.commands.Ringer
import com.familyshield.agent.enforcement.WindowLayout
import com.familyshield.agent.enforcement.WindowSnapshot
import com.familyshield.agent.security.GuardAttemptWindow
import com.familyshield.agent.security.GuardDebouncePolicy
import com.familyshield.agent.security.GuardWindow
import com.familyshield.agent.security.GuardCoverPolicy
import com.familyshield.agent.security.GuardGateState
import com.familyshield.agent.security.ParentPinStore
import com.familyshield.agent.security.TamperAlertWorker
import com.familyshield.agent.security.TamperGuardActivity
import com.familyshield.agent.security.TamperGuardTaskActivity
import com.familyshield.agent.security.TamperScreen
import com.familyshield.agent.security.ShadePolicy
import com.familyshield.agent.security.TamperScreenPolicy
import com.familyshield.agent.security.TamperState
import com.familyshield.agent.social.SocialCapture
import com.familyshield.agent.telemetry.FOREGROUND_HEARTBEAT_MS
import com.familyshield.agent.telemetry.UsageReporter
import com.familyshield.agent.vpn.FilterVpnService
import com.familyshield.agent.vpn.VpnState
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
    @Inject lateinit var deviceAdmin: com.familyshield.agent.security.DeviceAdminManager

    /** Issue #83 review F1 / #165: what the OS says a package is, shared with [AppBlocker]'s overlay guard. */
    @Inject lateinit var packageFacts: PackageFacts

    /** Issue #1174 & osra-security#80: live grant state + one-way completion latch so enforcement
     *  waits ONLY until required grants finish the first time for this device id, never weakening
     *  blocking if a grant is later revoked, and avoiding per-event IPC once latched. */
    private val grantChecks by lazy {
        com.familyshield.agent.setup.GrantChecks(this, deviceAdmin)
    }

    @Volatile private var latchedCompletedDeviceId: String? = null
    private var lastIncompleteGrantCheckElapsedMs: Long = 0L
    private var lastIncompleteMissingGrants: List<com.familyshield.agent.setup.OnboardingPolicy.Grant> = emptyList()

    private fun requiredGrantsIncompleteForPairedDevice(): Boolean {
        if (!settings.isPairedSync()) return false
        val deviceId = settings.deviceIdSync()
        if (deviceId != null && latchedCompletedDeviceId == deviceId) return false
        val upgradeSeeded = com.familyshield.agent.setup.SetupCompletionStore.seedUpgradeLatchIfNeeded(this, deviceId)
        val alreadyCompleted = com.familyshield.agent.setup.SetupCompletionStore.isCompletedForDevice(this, deviceId)
        if (alreadyCompleted && !upgradeSeeded) {
            latchedCompletedDeviceId = deviceId
            return false
        }
        val nowElapsed = SystemClock.elapsedRealtime()
        val missing: List<com.familyshield.agent.setup.OnboardingPolicy.Grant> = if (lastIncompleteGrantCheckElapsedMs != 0L &&
            nowElapsed - lastIncompleteGrantCheckElapsedMs < com.familyshield.agent.setup.FirstRunOrderPolicy.INCOMPLETE_RECHECK_INTERVAL_MS
        ) {
            lastIncompleteMissingGrants
        } else {
            val rows = com.familyshield.agent.setup.OnboardingPolicy.rows(
                com.familyshield.agent.BuildConfig.CAPTURE_NOTIFICATIONS,
            ) { grantChecks.isGranted(it) }
            val computed = com.familyshield.agent.setup.OnboardingPolicy.missingRequired(rows)
            lastIncompleteGrantCheckElapsedMs = nowElapsed
            lastIncompleteMissingGrants = computed
            computed
        }
        val ready = missing.isEmpty()
        if (ready && deviceId != null) {
            com.familyshield.agent.setup.SetupCompletionStore.markCompleted(this, deviceId)
            latchedCompletedDeviceId = deviceId
        }
        val suppressed = com.familyshield.agent.setup.FirstRunOrderPolicy.shouldSuppressEnforcement(
            paired = true,
            requiredGrantsReady = ready,
            setupCompletedOnce = alreadyCompleted || (ready && deviceId != null),
        )
        if (!ready && deviceId != null) {
            val fingerprint = com.familyshield.agent.setup.FirstRunOrderPolicy.missingGrantsFingerprint(missing)
            val lastNotified = com.familyshield.agent.setup.SetupCompletionStore.lastNotifiedMissingFingerprint(this, deviceId)
            if (com.familyshield.agent.setup.FirstRunOrderPolicy.shouldEnqueueMissingAlert(
                    paired = true,
                    setupCompletedOnce = alreadyCompleted,
                    currentFingerprint = fingerprint,
                    lastNotifiedFingerprint = lastNotified,
                    upgradeSeeded = upgradeSeeded,
                )
            ) {
                com.familyshield.agent.setup.SetupCompletionStore.recordNotifiedMissingFingerprint(this, deviceId, fingerprint)
                val labels = missing.map { getString(it.titleRes) }
                runCatching {
                    TamperAlertWorker.enqueue(
                        this,
                        TamperAlertWorker.TYPE_SETUP_INCOMPLETE,
                        detail = com.familyshield.agent.setup.FirstRunOrderPolicy.missingPermissionsAlertBody(labels),
                        app = fingerprint,
                    )
                }.onFailure { Log.w(TAG, "could not enqueue setup-incomplete alert (#1174)", it) }
            }
            if (alreadyCompleted && upgradeSeeded) {
                // Upgraded phone reported its newly required missing grants once; cache latch in memory
                // so future events avoid per-event IPC while keeping full protection active.
                latchedCompletedDeviceId = deviceId
            }
        }
        return suppressed
    }

    private var lastLocationCheckMs = 0L
    private var lastGuardMs = 0L

    /**
     * osra-security#29: the unbind handler writes two settings rows and both setters suspend. A service has no
     * lifecycle scope, and those writes must outlive the immediate unbind, so it gets its own.
     */
    private val serviceScope = CoroutineScope(SupervisorJob() + Dispatchers.IO)

    /**
     * Antigravity's R2 on #813: whether we held a location grant when the current PermissionController window was
     * entered. Latched on entry and cleared on leaving, so a parent granting "Allow all the time" during setup does
     * not trip the gate 50 ms later on the content change that follows the tap.
     */
    private var permissionWindowLocationActive: Boolean? = null

    /**
     * Antigravity's first note on Part 2: the special-access pages carry an inline toggle, so the moment a parent
     * flips it on during onboarding the grants change and a content change fires on the same window — which would
     * slam the gate over the parent's own setup. The set is latched on **entering** Settings and cleared on leaving,
     * so the visit is judged by what we held when it began.
     */
    private var specialAccessLatch: Set<TamperScreenPolicy.SpecialAccess>? = null

    /**
     * The location grant right now, in the same sense `GrantChecks.locationGranted()` uses: fine or coarse, **and**
     * background on Android 10 and later. Onboarding grants fine first and then opens this very page for
     * background, so a check that stopped at fine would say "we hold the grant" and slam the gate over setup
     * (Antigravity's re-review of #813).
     */
    /**
     * Part 2 of osra-security#29: which of the sibling special accesses we hold **right now**. A page for one we do
     * not hold is the parent granting it, so it is never a protection screen — this is the reader behind
     * `TamperScreenPolicy.ourSpecialAccess`.
     */
    private fun specialAccessHeld(): Set<TamperScreenPolicy.SpecialAccess> {
        val held = mutableSetOf<TamperScreenPolicy.SpecialAccess>()
        if (android.provider.Settings.canDrawOverlays(this)) held += TamperScreenPolicy.SpecialAccess.OVERLAY
        val appOps = getSystemService(android.app.AppOpsManager::class.java)
        if (appOps != null) {
            val mode = appOps.checkOpNoThrow(
                android.app.AppOpsManager.OPSTR_GET_USAGE_STATS,
                android.os.Process.myUid(),
                packageName,
            )
            if (mode == android.app.AppOpsManager.MODE_ALLOWED) held += TamperScreenPolicy.SpecialAccess.USAGE
        }
        val listeners = androidx.core.app.NotificationManagerCompat.getEnabledListenerPackages(this)
        if (listeners.contains(packageName)) held += TamperScreenPolicy.SpecialAccess.NOTIFICATIONS
        if (com.familyshield.agent.vpn.VpnState.isEnabled(this)) held += TamperScreenPolicy.SpecialAccess.VPN
        return held
    }

    private fun locationGrantedNow(): Boolean {
        val fine = ContextCompat.checkSelfPermission(this, android.Manifest.permission.ACCESS_FINE_LOCATION) == PackageManager.PERMISSION_GRANTED
        val coarse = ContextCompat.checkSelfPermission(this, android.Manifest.permission.ACCESS_COARSE_LOCATION) == PackageManager.PERMISSION_GRANTED
        if (!fine && !coarse) return false
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) return true
        return ContextCompat.checkSelfPermission(this, android.Manifest.permission.ACCESS_BACKGROUND_LOCATION) == PackageManager.PERMISSION_GRANTED
    }

    /** #734: when the ring screen was last brought back, on the monotonic clock (#802, Claude's V1). */
    private var lastRingRestoreMs = 0L

    /** #734 / #802 V2: the one delayed re-check at the end of the debounce, if one is pending. */
    private var ringRecheck: Runnable? = null
    private val ringRecheckHandler = android.os.Handler(android.os.Looper.getMainLooper())

    private enum class ShadePulse { STATE, LATE, CONTENT }

    private var shadeRecheck: Runnable? = null
    private var shadeLateRecheck: Runnable? = null
    private var shadeContentRecheck: Runnable? = null
    private var ringWindowExpiry: Runnable? = null

    /** osra-security#7: the window the gate was last opened over; a state change from any other is a new screen. */
    private var guardedWindowId = -1
    /**
     * #802 V5 (Claude): the class of the last state change **per package**. A single pair was overwritten by
     * whichever package spoke last — the keyboard when a parent taps the PIN field — after which
     * `isRingScreen` saw a foreign class, and the ring screen was raised over the PIN gate it must never cover.
     *
     * Antigravity's Flip4 pass (#817) closed the same hole on the special-access pages: a global pair was also
     * erased by the search keyboard, so `classify()` saw no class at all while the child typed in Search. This is
     * now the only copy, and `classify()` reads it by the foreground package.
     */
    private val lastClassByPkg = HashMap<String, String>()

    /**
     * Issue #175: bounded re-raises of the lock overlay for a PiP / split screen state the platform may
     * refuse to change; resets when the visible window state changes (see [WindowSnapshot.signature]).
     */
    private val lockRetryBudget = OverlayRetryBudget()

    /** One `block_bypass` alert per app per ten minutes, shared by the window path and the call path (#449). */
    private val bypassFloor = BypassAlertFloor()

    /**
     * Issue #175 (reopened): the block overlay's own rule. In the normal layout a blocked app that comes
     * back on top (the Meet call screen) is sent Home and covered again every time, a second apart; in
     * PiP and split screen two raises, then one `tamper` alert to the parent.
     */
    private val blockRaisePolicy = BlockRaisePolicy(floor = bypassFloor)

    /** Issue #175: the cover over a blocked PiP window, which stays above the block screen otherwise. */
    private val pipCover by lazy { PipCoverOverlay(this) }
    /** osra-security#7: the cover over a protection screen that shares the screen ([GuardCoverPolicy]). */
    private val guardCover by lazy { PipCoverOverlay(this) }
    private var guardCoverBounds: WindowBounds? = null

    /** Issue #460: the fallback that raises the deferred block screen when no launcher event arrives. */
    private val main = android.os.Handler(android.os.Looper.getMainLooper())
    private val deferredRaise = Runnable { raiseDeferredIfDue() }

    /** Issue #444 / osra-security#33 / osra-security#48: non-essential calls are blocked under app rules and active lock/pause; essential packages stay exempt. */
    private val calls by lazy {
        CallEnforcer(
            this,
            isBlocked = {
                isNonEssentialBlocked(
                    isEssential = EssentialPackages.isEssential(it, packageFacts),
                    lockedOrRuleBlocked = LockState.isActive(this) || rules.evaluate(it) != RuleRepository.Decision.ALLOW,
                )
            },
            isEssential = { EssentialPackages.isEssential(it, packageFacts) },
            floor = bypassFloor,
        )
    }

    /** Issue #444 C4: a rule sync may have just blocked an app that is playing; the check runs on the main thread. */
    private val rulesChanged: () -> Unit = {
        android.os.Handler(android.os.Looper.getMainLooper()).post { media.onRulesChanged() }
    }

    /** Issue #444 C4 / osra-security#33 / osra-security#48: non-essential media sessions also pause while locked or paused. */
    private val media by lazy {
        MediaEnforcer(
            this,
            isBlocked = {
                isNonEssentialBlocked(
                    isEssential = EssentialPackages.isEssential(it, packageFacts),
                    lockedOrRuleBlocked = LockState.isActive(this) || rules.evaluate(it) != RuleRepository.Decision.ALLOW,
                )
            },
        )
    }

    /** Issue #132: log a refused start once per reason, not once per 60 s accessibility event. */
    private var loggedStartDecision: LocationStartPolicy.Decision? = null

    /** Issue #83 review F1: the dialer/system flags are cached for the hot path, so refresh on package changes. */
    private val packageChangeReceiver = object : BroadcastReceiver() {
        override fun onReceive(context: android.content.Context?, intent: Intent?) = packageFacts.refresh()
    }

    /** #830 row 5: periodic local foreground heartbeat while interactive; stops completely while screen is off. */
    private val foregroundHeartbeat = object : Runnable {
        override fun run() {
            val interactive = runCatching {
                getSystemService(android.os.PowerManager::class.java)?.isInteractive ?: false
            }.getOrDefault(false)
            if (!interactive) return
            usage.recordActiveHeartbeat(System.currentTimeMillis())
            main.postDelayed(this, FOREGROUND_HEARTBEAT_MS)
        }
    }

    private fun scheduleForegroundHeartbeat() {
        main.removeCallbacks(foregroundHeartbeat)
        main.postDelayed(foregroundHeartbeat, FOREGROUND_HEARTBEAT_MS)
    }

    private val screenStateReceiver = object : BroadcastReceiver() {
        override fun onReceive(context: android.content.Context?, intent: Intent?) {
            when (intent?.action) {
                Intent.ACTION_SCREEN_OFF -> {
                    main.removeCallbacks(foregroundHeartbeat)
                    serviceScope.launch { usage.onScreenOff(System.currentTimeMillis()) }
                    FilterVpnService.flushIfRunning(this@AccessibilityMonitorService)
                }
                Intent.ACTION_SCREEN_ON -> scheduleForegroundHeartbeat()
            }
        }
    }

    private val filterRecoveryCovers = mutableMapOf<WindowBounds, PipCoverOverlay>()

    private val filterLossReceiver = object : BroadcastReceiver() {
        override fun onReceive(context: android.content.Context?, intent: Intent?) {
            if (intent?.action == VpnState.ACTION_FILTER_LOSS_CHANGED) refreshFilterRecovery()
        }
    }

    override fun onServiceConnected() {
        super.onServiceConnected()
        // Issue #231 review: this callback is the system telling us it has bound the service, so it
        // is the authoritative "accessibility is running" for EnforceabilityPolicy — not the
        // ENABLED_ACCESSIBILITY_SERVICES setting, which stays true while the service is not alive.
        isRunning = true
        // Back on: the shared moment is cleared, the next switch-off starts a new alert.
        TamperState.setAccessibilityDisabledAt(this, 0L)
        // U2b: the poll compares the last observation with the current one, so a bind has to record "on" — without
        // it a re-enable never clears the state and the next unbind is silent.
        serviceScope.launch { runCatching { settings.recordAccessibilityEnabled(true) } }
        val filter = IntentFilter().apply {
            addAction(Intent.ACTION_PACKAGE_ADDED)
            addAction(Intent.ACTION_PACKAGE_REPLACED)
            addAction(Intent.ACTION_PACKAGE_REMOVED)
            addDataScheme("package")
        }
        runCatching { registerReceiver(packageChangeReceiver, filter) }
        val screenFilter = IntentFilter().apply {
            addAction(Intent.ACTION_SCREEN_OFF)
            addAction(Intent.ACTION_SCREEN_ON)
        }
        runCatching { registerReceiver(screenStateReceiver, screenFilter) }
        val interactiveNow = runCatching {
            getSystemService(android.os.PowerManager::class.java)?.isInteractive ?: false
        }.getOrDefault(false)
        if (interactiveNow) scheduleForegroundHeartbeat()
        ContextCompat.registerReceiver(
            this,
            filterLossReceiver,
            IntentFilter(VpnState.ACTION_FILTER_LOSS_CHANGED),
            ContextCompat.RECEIVER_NOT_EXPORTED,
        )
        refreshFilterRecovery()
        // Issue #1174 / osra-security#80: evaluate setup completion once on connect so upgraded
        // already-complete devices latch immediately and incomplete paired phones emit one alert.
        requiredGrantsIncompleteForPairedDevice()
        calls.onConnected()
        media.onConnected()
        bindRingWindowCallbacks(
            scheduler = object : IncomingRingWindow.Scheduler {
                override fun schedule(delayMs: Long, action: () -> Unit) {
                    ringWindowExpiry?.let { ringRecheckHandler.removeCallbacks(it) }
                    val task = Runnable {
                        ringWindowExpiry = null
                        action()
                    }
                    ringWindowExpiry = task
                    ringRecheckHandler.postDelayed(task, delayMs.coerceAtLeast(0L))
                }

                override fun cancel() {
                    ringWindowExpiry?.let { ringRecheckHandler.removeCallbacks(it) }
                    ringWindowExpiry = null
                }
            },
            onClosed = {
                ringRecheckHandler.post { collapseShadeAfterRingEnded() }
            },
        )
        rules.addRulesChangedListener(rulesChanged)
    }

    override fun onUnbind(intent: Intent?): Boolean {
        // Called when the system is about to unbind (the user turned the service off, or it was
        // replaced); onDestroy follows, but the command poll must see the service as gone at once.
        isRunning = false
        // osra-security#29, second half (the Flip4 AS02 row): the poll hears about this in up to 60 s, and not at
        // all when the location grant is off — which is exactly the phone where the child turned accessibility
        // off to stop blocking. Tell the parent now, through the worker so it retries offline.
        val unboundAt = System.currentTimeMillis()
        // Antigravity's fix on osra-security#29: stamp the moment synchronously, so the poll (which may run first on
        // reconnect) and this alert share one dedupe key instead of paging twice.
        TamperState.setAccessibilityDisabledAt(this, unboundAt)
        // U2a (Antigravity): a parent who turned accessibility off inside the PIN's grace window, or a phone that
        // was never paired, must not produce a critical alert — that is the parent's own action.
        if (com.familyshield.agent.receivers.AccessibilityOffPolicy.shouldTellParent(
                paired = settings.isPairedSync(),
                graceUntilMs = TamperState.graceUntil(this),
                nowMs = unboundAt,
            )
        ) {
            // U2b: the state the poll reads is now written inside the worker, before its POST. Doing it here on a
            // scope that onDestroy() cancels was a race that could drop both writes and let the poll repeat it.
            runCatching {
                TamperAlertWorker.enqueue(
                    this,
                    TamperAlertWorker.TYPE_ACCESSIBILITY_OFF,
                    detail = "The OSRA accessibility service was turned off on this device",
                    eventAtMs = unboundAt,
                )
            }.onFailure { Log.w(TAG, "could not enqueue the accessibility-off alert (#29)", it) }
        }
        return super.onUnbind(intent)
    }

    override fun onDestroy() {
        isRunning = false
        serviceScope.cancel()
        // #802 V2: no re-check outlives the service; a pending one would try to raise a screen from a dead
        // component.
        ringRecheck?.let { ringRecheckHandler.removeCallbacks(it) }
        ringRecheck = null
        shadeRecheck?.let { ringRecheckHandler.removeCallbacks(it) }
        shadeRecheck = null
        shadeLateRecheck?.let { ringRecheckHandler.removeCallbacks(it) }
        shadeLateRecheck = null
        shadeContentRecheck?.let { ringRecheckHandler.removeCallbacks(it) }
        shadeContentRecheck = null
        ringWindowExpiry?.let { ringRecheckHandler.removeCallbacks(it) }
        ringWindowExpiry = null
        IncomingRingWindow.unbindCallbacks()
        calls.onDestroy()
        media.onDestroy()
        rules.removeRulesChangedListener(rulesChanged)
        pipCover.remove()
        guardCover.remove()
        updateFilterRecoveryCovers(emptySet())
        // #460 review: a deferred raise posted inside the fallback window must not fire after the
        // service is gone — the child turning accessibility off is exactly when that window exists.
        cancelDeferredRaise()
        main.removeCallbacks(foregroundHeartbeat)
        runCatching { unregisterReceiver(screenStateReceiver) }
        runCatching { unregisterReceiver(packageChangeReceiver) }
        runCatching { unregisterReceiver(filterLossReceiver) }
        super.onDestroy()
    }

    override fun onAccessibilityEvent(event: AccessibilityEvent?) {
        // Issue #444: notification events carry calls only; they never feed the window logic below.
        // RuleRepository.evaluate already answers ALLOW for everything while consent is paused.
        if (event?.eventType == AccessibilityEvent.TYPE_NOTIFICATION_STATE_CHANGED) {
            calls.onNotification(event)
            media.onNotification(event)
            return
        }
        // osra-security#7: a window opened, closed, moved or resized (split screen, pop-up, freeform). It names no
        // package, and only the guard's cover needs it.
        if (event?.eventType == AccessibilityEvent.TYPE_WINDOWS_CHANGED) {
            coverSharedProtectionScreens()
            refreshFilterRecovery()
            return
        }
        val eventPkg = event?.packageName?.toString() ?: return
        calls.onEvent()
        if (event.eventType == AccessibilityEvent.TYPE_WINDOW_STATE_CHANGED &&
            ShadePolicy.shouldCollapse(
                locked = LockState.isActive(this),
                packageName = eventPkg,
                className = event.className?.toString(),
                apiLevel = android.os.Build.VERSION.SDK_INT,
                callRinging = calls.isRinging(),
            )
        ) {
            performGlobalAction(GLOBAL_ACTION_DISMISS_NOTIFICATION_SHADE)
            scheduleShadeRecheck(delayMs = SHADE_RECHECK_MS, slot = ShadePulse.STATE)
            scheduleShadeRecheck(delayMs = SHADE_LATE_RECHECK_MS, slot = ShadePulse.LATE)
        }
        if (event.eventType == AccessibilityEvent.TYPE_WINDOW_CONTENT_CHANGED &&
            ShadePolicy.shouldCollapseOnContentChange(
                locked = LockState.isActive(this),
                packageName = eventPkg,
                lastKnownClass = lastClassByPkg[eventPkg],
                apiLevel = android.os.Build.VERSION.SDK_INT,
                callRinging = calls.isRinging(),
            )
        ) {
            scheduleShadeRecheck(delayMs = SHADE_CONTENT_RECHECK_MS, slot = ShadePulse.CONTENT)
        }
        // osra-security#7: before the own-window return below, which our gate's events take.
        if (event.eventType == AccessibilityEvent.TYPE_WINDOW_STATE_CHANGED ||
            TamperScreenPolicy.mayHostProtectionScreen(eventPkg)
        ) coverSharedProtectionScreens()
        // #802 item 3 (Hydrogen): the window class is tracked and the ring check runs **before** the
        // own-package return below. Our own windows are exactly the case that matters — the child app's
        // launcher activity is the osra-security#31 escape, and RingActivity/the PIN gate are the two classes
        // the policy must recognise — and the return used to skip both.
        if (event.eventType == AccessibilityEvent.TYPE_WINDOW_STATE_CHANGED) {
            event.className?.toString()?.let { lastClassByPkg[eventPkg] = it }
            val nextSystemUi = ShadePolicy.nextSystemUiClass(
                current = lastClassByPkg[ShadePolicy.SHADE_PACKAGE],
                eventPkg = eventPkg,
                eventClass = event.className?.toString(),
            )
            if (nextSystemUi == null) {
                lastClassByPkg.remove(ShadePolicy.SHADE_PACKAGE)
            } else {
                lastClassByPkg[ShadePolicy.SHADE_PACKAGE] = nextSystemUi
            }
        }
        if (eventPkg == packageName) {
            // Issue #284: our own block screen is in front and this stream never records our package, so
            // the blocked app's interval would stay open and the next real event would charge it the stay.
            usage.recordOwnWindow(System.currentTimeMillis())
            // #813 review (Claude): returning to OSRA ends any PermissionController visit, so a latch set during
            // onboarding must not survive it and hide the next real visit.
            permissionWindowLocationActive = null
            // A jump straight back into OSRA ends the Settings visit, so the latch goes with it. **No unit row
            // covers this line** (Claude's item 1 on #817): the pure rule's else-branch returns null for any package
            // that is not Settings, so a row there would pass with or without this assignment. A service-level test
            // is owed; until then this is a comment a reader can check, not a claim of coverage.
            specialAccessLatch = null
            restoreRingScreen(event, packageName)
            return
        }
        // Issue #175: read every visible application window once per event. The active window alone
        // cannot name a PiP video or the blocked app in the other split pane, and #171's active-only
        // decision therefore never judged them.
        val snapshot = windowSnapshot()
        // Issue #165 (reopened): the event's package is a hint, not "the app in front". On the Flip4,
        // WM-Shell reports the Home transition under the framework package `android`; deciding from
        // that name answered BLOCK for a screen that is not an app and the overlay covered the launcher.
        val foreground = resolveForeground(event, eventPkg, snapshot)
        ensureLocationServiceRunning()
        // ADR-0010 §3: the protection guard runs even while consent is paused — a paused agent is
        // still an installed one, and the parent must still hear about an uninstall attempt.
        guardProtectionScreens(event, foreground)
        // #734: Home is not a way out of a ring. While the ring runs, anything that is not our own window
        // brings the ring screen back — its only exit is the parent PIN, and the alarm has no other stop.
        restoreRingScreen(event, foreground)
        // The lock is the safe direction: when the window in front cannot be named, the event package
        // is the only hint and the overlay must still come back (LockEnforcementPolicy decides).
        enforceLockState(snapshot, foreground ?: eventPkg)
        // ADR-0008 §3: consent withdrawn — the service keeps polling (to learn about a re-grant) but
        // records, captures and enforces nothing.
        if (consentState.isPaused()) {
            pipCover.remove()
            updateFilterRecoveryCovers(emptySet())
            // #460 review: consent withdrawn inside the fallback window must not still show a block
            // screen — ADR-0008 §3 says a paused agent records, captures and enforces nothing.
            cancelDeferredRaise()
            social.onMonitoringPaused()
            return
        }
        if (enforceFilterRecovery(snapshot, foreground)) {
            cancelDeferredRaise()
            return
        }
        // Usage and social capture belong to the app actually in front; our own overlay and the
        // unresolved framework package are neither.
        if (foreground != null && foreground != packageName) {
            // Feature #2/#17: social/chat text capture for monitored apps (no-op elsewhere).
            social.onAccessibilityEvent(event)
            if (foreground != eventPkg) Log.i(TAG, "event package $eventPkg, window in front $foreground (#165)")
            usage.recordForeground(foreground, System.currentTimeMillis())
        } else if (foreground == packageName) {
            // #284: the window in front is our own overlay (a block or time-limit screen) while the
            // event came from somewhere else. Close the blocked app's interval here too, or the time
            // the child spends reading "Daily limit reached" is charged to the app behind it.
            usage.recordOwnWindow(System.currentTimeMillis())
        }
        // Issue #175: judge every visible application window, including one in the other split pane
        // or a PiP window over Home. This runs even when our own overlay is the active window, which
        // is exactly the split-screen case the child uses to keep the blocked app beside the lock.
        enforceVisibleBlocks(snapshot, foreground)
        // Issue #460: the launcher may be the Home we asked for, so the deferred block screen goes on
        // top of it. Called after the block step, which may have deferred a new raise this event.
        advanceDeferredRaise(foreground ?: eventPkg)
    }

    private fun refreshFilterRecovery() {
        // Issue #1174 (path 2): never show filter-lost recovery while initial required grants are incomplete.
        if (requiredGrantsIncompleteForPairedDevice() || !VpnState.isFilterLost(this, settings, consentState)) {
            updateFilterRecoveryCovers(emptySet())
            return
        }
        val snapshot = windowSnapshot()
        enforceFilterRecovery(snapshot, snapshot.activePackage)
    }

    private fun enforceFilterRecovery(snapshot: WindowSnapshot, foreground: String?): Boolean {
        if (requiredGrantsIncompleteForPairedDevice() ||
            !VpnState.isFilterLost(this, settings, consentState) ||
            LockState.isActive(this) || Ringer.isRinging ||
            getSystemService(android.app.KeyguardManager::class.java)?.isKeyguardLocked == true
        ) {
            updateFilterRecoveryCovers(emptySet())
            return false
        }
        val ownConsentPending = VpnState.hasPendingOwnConsent()
        val presentation = FilterRecoveryPolicy.presentation(snapshot, foreground) { pkg ->
            pkg == packageName || EssentialPackages.isEssential(pkg, packageFacts) ||
                pkg == TamperScreenPolicy.VPN_DIALOG_PACKAGE && ownConsentPending
        }
        updateFilterRecoveryCovers(presentation.coveredWindows)
        presentation.blockedForeground?.let(blocker::showFilterRecovery)
        return presentation.blockedForeground != null || presentation.coveredWindows.isNotEmpty()
    }

    private fun updateFilterRecoveryCovers(bounds: Set<WindowBounds>) {
        (filterRecoveryCovers.keys - bounds).forEach { old -> filterRecoveryCovers.remove(old)?.remove() }
        bounds.forEach { target ->
            filterRecoveryCovers.getOrPut(target) { PipCoverOverlay(this) }.update(target)
        }
    }

    /**
     * Issue #460: show the screen a blocked package gets, once it is time to show it.
     */
    private fun raiseBlockOrTimeLimit(pkg: String, blocked: Boolean, window: WindowReason? = null) {
        // The policy owns the spacing (1 s); AppBlocker's own 2 s debounce would halve it.
        blocker.clearDebounce(pkg)
        media.onRaise(pkg) // #444 C4: pause the blocked app's media when its screen goes up
        // Issue #473: the screen names the window when one fired; a time limit and every other block
        // pass no window and keep the existing copy.
        if (blocked) blocker.showBlockScreen(pkg, window) else blocker.showTimeLimitScreen(pkg)
    }

    /**
     * Issue #460: a launcher in front while a raise is deferred means the Home we asked for has landed,
     * so the block screen can go on top of it. Every event also advances the fallback, so a launcher
     * that reports nothing still gets the raise.
     */
    private fun advanceDeferredRaise(frontPackage: String?) {
        val launcherFront = frontPackage != null && packageFacts.homePackages().contains(frontPackage)
        val deferred = blockRaisePolicy.launcherFront(
            launcherFront = launcherFront,
            nowMs = System.currentTimeMillis(),
        ) ?: return
        main.removeCallbacks(deferredRaise)
        raiseBlockOrTimeLimit(deferred.pkg, deferred.blocked, deferred.window)
    }

    /**
     * Issue #460 review: the fallback, which must not re-check the wall clock.
     *
     * The Runnable is always reposted for the latest pending raise, so when it runs it is due by
     * construction. Reading `now` again let a backwards clock step (NTP, or the user setting the time)
     * find `expired == false`, return without raising and post no retry — and with a launcher that
     * reports no event, that is the app staying blocked with no screen.
     */
    private fun raiseDeferredIfDue() {
        if (consentState.isPaused() || requiredGrantsIncompleteForPairedDevice()) {
            cancelDeferredRaise()
            return
        }
        val deferred = blockRaisePolicy.launcherFront(
            launcherFront = true,
            nowMs = System.currentTimeMillis(),
        ) ?: return
        raiseBlockOrTimeLimit(deferred.pkg, deferred.blocked, deferred.window)
    }

    /**
     * Issue #460 review: drop a deferred raise — consent is paused, or the service is going away.
     *
     * Without this the posted Runnable survived both: a consent withdrawn inside the fallback window
     * still showed a block screen (ADR-0008 §3 forbids it), and a service destroyed inside the window
     * raised after `onDestroy`.
     */
    private fun cancelDeferredRaise() {
        main.removeCallbacks(deferredRaise)
        blockRaisePolicy.clearPendingRaise()
    }

    /**
     * Issue #175: run the same [RuleRepository.evaluate] over every visible application package —
     * [EssentialPackages.blockCandidates] returns the active app first and then the rest. The first
     * non-ALLOW answer is handed to [blockRaisePolicy], which says whether to go Home, raise the
     * overlay again, or tell the parent the app stayed on screen. A blocked app in PiP is also covered
     * by [pipCover], because a PiP window stays above the block screen.
     */
    private fun enforceVisibleBlocks(snapshot: WindowSnapshot, active: String?) {
        // Issue #1174: no app-block or routine enforcement until all required onboarding grants are done.
        if (requiredGrantsIncompleteForPairedDevice()) {
            pipCover.update(null)
            cancelDeferredRaise()
            return
        }
        val found = VisibleBlockStep.decide(
            snapshot,
            active,
            evaluate = rules::verdict,
            isEssential = { EssentialPackages.isEssential(it, packageFacts) },
            policy = blockRaisePolicy,
            nowMs = System.currentTimeMillis(),
        )
        if (found == null) {
            pipCover.update(null)
            return
        }
        val (pkg, verdict, step) = found
        val decision = verdict.decision
        val layout = snapshot.layout
        val pipWindow = snapshot.windows.firstOrNull { it.inPictureInPicture && it.packageName == pkg }
        pipCover.update(pipWindow?.bounds)
        if (step.goHome) performGlobalAction(GLOBAL_ACTION_HOME)
        if (step.raise) {
            if (pipWindow != null) dismissPictureInPicture(pkg)
            val blocked = decision == RuleRepository.Decision.BLOCK
            if (step.goHome) {
                // Issue #460: Home and startActivity are both asynchronous and nothing ordered them, so
                // the launcher landed on top of the block screen — 4 of 4 on the Flip4, and the child
                // saw no "blocked by your parent" screen at all. The raise now waits for the launcher's
                // own window event, with a fallback for launchers that never report one.
                blockRaisePolicy.noteHomeSent(pkg, blocked, System.currentTimeMillis(), verdict.reason)
                main.removeCallbacks(deferredRaise)
                main.postDelayed(deferredRaise, BlockRaisePolicy.DEFAULT_HOME_FALLBACK_MS)
            } else {
                raiseBlockOrTimeLimit(pkg, blocked, verdict.reason)
            }
        }
        if (step.reportBypass) {
            Log.w(TAG, "block overlay: $pkg still visible in ${layout.name.lowercase()} after the raises; telling the parent (#175)")
            TamperAlertWorker.enqueue(
                this,
                TamperAlertWorker.TYPE_BLOCK_BYPASS,
                eventAtMs = step.episodeStartMs,
                app = pkg,
                layout = layout.name.lowercase(),
            )
        }
    }

    /**
     * Issue #175: best effort. Some PiP windows expose `ACTION_DISMISS` on their root; most do not,
     * which is why the cover exists. The result is logged so the hardware row can say which it was.
     */
    private fun dismissPictureInPicture(pkg: String) {
        for (window in runCatching { windows }.getOrNull().orEmpty()) {
            try {
                if (!runCatching { window.isInPictureInPictureMode }.getOrDefault(false)) continue
                val root = runCatching { window.root }.getOrNull() ?: continue
                try {
                    if (runCatching { root.packageName?.toString() }.getOrNull() != pkg) continue
                    val dismissed = runCatching { root.performAction(AccessibilityNodeInfo.ACTION_DISMISS) }.getOrDefault(false)
                    Log.i(TAG, "PiP dismiss for $pkg: ${if (dismissed) "accepted" else "not supported"} (#175)")
                } finally {
                    runCatching { root.recycle() }
                }
            } finally {
                runCatching { window.recycle() }
            }
        }
    }

    /**
     * Issue #175: the budget is per screen state ([WindowSnapshot.signature]), not per package. A
     * child who closes PiP or leaves split produces a new signature and gets a fresh attempt; a state
     * the platform refuses to change is logged once and then left alone instead of looping.
     */
    private fun allowOverlay(
        budget: OverlayRetryBudget,
        signature: String,
        layout: WindowLayout,
        what: String,
    ): Boolean = when (budget.attempt(signature)) {
        RetryDecision.ATTEMPT -> true
        RetryDecision.EXHAUSTED_ONCE -> {
            Log.w(
                TAG,
                "$what overlay: retry budget exhausted in ${layout.name.lowercase()} " +
                    "[$signature] — the window state (picture-in-picture / split screen) did not " +
                    "change; not starting another overlay",
            )
            false
        }
        RetryDecision.EXHAUSTED -> false
    }

    /**
     * Issue #165 (reopened): the package of the window actually in front, so a block decision is made
     * about the screen the child is looking at rather than about whoever emitted the event.
     *
     * Every event is resolved, because the event package is wrong in more than the Home case: a
     * content-change event from an app in the **background** names that app, and deciding from it
     * raised the overlay over whatever was really in front. Measured on the Flip4 during the reopened
     * run: the overlay's subtitle read `com.samsung.android.spay` while the dialer/launcher held focus,
     * and pressing Home from that overlay put the overlay back within two seconds. The active window
     * is the authority; the event's own source and then its package are only fallbacks, and none of
     * them is trusted when it names [EssentialPackages.FRAMEWORK_PACKAGE].
     *
     * Cost: reading the active window's root and the window list costs one binder call each per event,
     * and the service is configured for `typeWindowStateChanged|typeWindowContentChanged` at a 100 ms
     * throttle, so this is at most ten walks a second — the same order as the read [SocialCapture]
     * already does for a monitored app.
     */
    private fun resolveForeground(event: AccessibilityEvent, eventPkg: String, snapshot: WindowSnapshot): String? {
        val fromSnapshot = EssentialPackages.foregroundPackage(eventPkg, snapshot.activePackage)
        if (fromSnapshot != null) return fromSnapshot
        // The window list may not be available (some OEMs), but `event.source` can still name the
        // window the event came from. It is a fallback, never the authority.
        val source = runCatching { event.source }.getOrNull()
        val fromSource = runCatching { source?.packageName?.toString() }.getOrNull()
        runCatching { source?.recycle() }
        return EssentialPackages.foregroundPackage(eventPkg, fromSource)
    }

    /**
     * Issue #175: one snapshot of the windows the OS reports, taken once per event.
     *
     * `windows` is populated because the accessibility config requests `flagRetrieveInteractiveWindows`.
     * Only [AccessibilityWindowInfo.TYPE_APPLICATION] windows are application content; the IME,
     * system bars and the split divider are not block candidates.
     *
     * Every node and window obtained here is recycled — #175's second finding: `rootInActiveWindow`
     * was never recycled, and on API 26–32 every unrecycled [AccessibilityNodeInfo] is a native leak
     * in a service that can run this path ten times a second.
     */
    private fun windowSnapshot(): WindowSnapshot {
        var active: String? = null
        val activeRoot = runCatching { rootInActiveWindow }.getOrNull()
        if (activeRoot != null) {
            active = runCatching { activeRoot.packageName?.toString() }.getOrNull()
                ?.takeIf { it.isNotBlank() && it != EssentialPackages.FRAMEWORK_PACKAGE }
            runCatching { activeRoot.recycle() }
        }
        val visible = ArrayList<VisibleWindow>(4)
        // The `windows` read itself can fail if the service lost the flag; treat that as "no list"
        // and let the event-package fallback in resolveForeground do its job.
        for (window in runCatching { windows }.getOrNull().orEmpty()) {
            try {
                if (window.type == AccessibilityWindowInfo.TYPE_APPLICATION) {
                    val root = runCatching { window.root }.getOrNull()
                    val pkg = runCatching { root?.packageName?.toString() }.getOrNull()
                    runCatching { root?.recycle() }
                    if (!pkg.isNullOrBlank()) {
                        visible.add(
                            VisibleWindow(
                                packageName = pkg,
                                inPictureInPicture = runCatching { window.isInPictureInPictureMode }.getOrDefault(false),
                                bounds = runCatching {
                                    val r = android.graphics.Rect()
                                    window.getBoundsInScreen(r)
                                    WindowBounds(r.left, r.top, r.right, r.bottom)
                                }.getOrNull(),
                            ),
                        )
                    }
                }
            } finally {
                runCatching { window.recycle() }
            }
        }
        return WindowSnapshot(active, visible)
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
     * #734 (Flip4, 13 Nov): while [Ringer.isRinging], bring the ring screen back in front of whatever the
     * child opened. Home cannot be swallowed by an activity, and #731 put the screen in its own hidden task,
     * so without this the alarm rings with no way to stop it on the phone.
     *
     * The decision is [RingReentryPolicy]'s — not our own window, debounced, and never when the clock has
     * gone backwards. Only a window change is considered: a content change inside an app is not a screen.
     */
    private fun restoreRingScreen(event: AccessibilityEvent, foreground: String?) {
        if (event.eventType != AccessibilityEvent.TYPE_WINDOW_STATE_CHANGED) return
        // Claude's V1 on #802: the monotonic clock, as #792 uses — a wall-clock change must not delay the
        // screen coming back.
        val now = SystemClock.elapsedRealtime()
        val classOfForeground = foreground?.let { lastClassByPkg[it] }
        when (RingReentryPolicy.decide(
            isRinging = Ringer.isRinging,
            foreground = foreground,
            foregroundClass = classOfForeground,
            ownPackage = packageName,
            nowElapsedMs = now,
            lastRestoreElapsedMs = lastRingRestoreMs,
        )) {
            RingReentryPolicy.Reentry.RESTORE -> {
                lastRingRestoreMs = now
                raiseRingScreen()
            }
            // Claude's V2 on #802: declined only because of the debounce is not "nothing to do" — the child
            // pressed Home a moment after the last launch, and without this the launcher stays in front until
            // something else opens.
            RingReentryPolicy.Reentry.DEFER -> scheduleRingRecheck()
            RingReentryPolicy.Reentry.IGNORE -> Unit
        }
    }

    /** Brings the ring screen to the front, in the task #731 gave it. */
    private fun raiseRingScreen() {
        runCatching {
            startActivity(
                Intent(this, RingActivity::class.java)
                    .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_REORDER_TO_FRONT),
            )
        }.onFailure { Log.w(TAG, "could not bring the ring screen back (#734)", it) }
    }

    private fun scheduleShadeRecheck(delayMs: Long, slot: ShadePulse) {
        if (shadePulse(slot) != null) return
        val task = Runnable {
            setShadePulse(slot, null)
            if (!ShadePolicy.shouldRecheck(LockState.isActive(this), calls.isRinging())) return@Runnable
            performGlobalAction(GLOBAL_ACTION_DISMISS_NOTIFICATION_SHADE)
        }
        setShadePulse(slot, task)
        ringRecheckHandler.postDelayed(task, delayMs)
    }

    private fun shadePulse(slot: ShadePulse): Runnable? = when (slot) {
        ShadePulse.STATE -> shadeRecheck
        ShadePulse.LATE -> shadeLateRecheck
        ShadePulse.CONTENT -> shadeContentRecheck
    }

    private fun setShadePulse(slot: ShadePulse, task: Runnable?) {
        when (slot) {
            ShadePulse.STATE -> shadeRecheck = task
            ShadePulse.LATE -> shadeLateRecheck = task
            ShadePulse.CONTENT -> shadeContentRecheck = task
        }
    }

    /** One delayed re-check at the end of the debounce; it does nothing if the ring has stopped by then. */
    private fun scheduleRingRecheck() {
        if (ringRecheck != null) return
        val task = Runnable {
            ringRecheck = null
            if (!Ringer.isRinging) return@Runnable
            // #802 V4 (Claude): decide again on the window that is in front **now**. The screen it deferred
            // over may have become the PIN gate in the meantime, and raising the ring screen over a parent
            // typing their PIN is the one thing the exemption exists to prevent.
            // Hydrogen's item 2 (#802): the node is a native allocation; recycle it like windowSnapshot() does.
            val inFront = runCatching {
                val root = rootInActiveWindow ?: return@runCatching null
                try {
                    root.packageName?.toString()
                } finally {
                    runCatching { root.recycle() }
                }
            }.getOrNull()
            val clsNow = inFront?.let { lastClassByPkg[it] }
            val now = SystemClock.elapsedRealtime()
            when (RingReentryPolicy.decide(
                isRinging = true,
                foreground = inFront,
                foregroundClass = clsNow,
                ownPackage = packageName,
                nowElapsedMs = now,
                lastRestoreElapsedMs = lastRingRestoreMs,
            )) {
                RingReentryPolicy.Reentry.RESTORE -> {
                    lastRingRestoreMs = now
                    raiseRingScreen()
                }
                RingReentryPolicy.Reentry.DEFER -> scheduleRingRecheck()
                RingReentryPolicy.Reentry.IGNORE -> Unit
            }
        }
        ringRecheck = task
        ringRecheckHandler.postDelayed(task, RingReentryPolicy.DEBOUNCE_MS)
    }

    /**
     * ADR-0010 §3: when the foreground window is the OS screen that would strip protection
     * (deactivate admin / uninstall / app-info for this package), step in front of it with the
     * parent-PIN gate and tell the parent. Cheap by construction: only window-change events from
     * system packages are inspected, texts are read once, and a 1.5-s debounce stops the gate from
     * being launched twice for the same screen.
     */
    private fun guardProtectionScreens(event: AccessibilityEvent, pkg: String?) {
        if (event.eventType != AccessibilityEvent.TYPE_WINDOW_STATE_CHANGED &&
            event.eventType != AccessibilityEvent.TYPE_WINDOW_CONTENT_CHANGED
        ) return
        // osra-security#5: the window's class is what the screen IS, in any language. A state change
        // carries the activity or dialog class; a content change carries a view class, so the last state
        // change's class is kept and used only while the same package is in front.
        if (event.eventType == AccessibilityEvent.TYPE_WINDOW_STATE_CHANGED) {
            val pkgOfEvent = event.packageName?.toString()
            if (pkgOfEvent != null) event.className?.toString()?.let { lastClassByPkg[pkgOfEvent] = it }
            // Antigravity's Flip4 pass (#817): a soft keyboard's state change arrives with the IME's package, so
            // `pkgOfEvent` is the IME — not the page under it. Taking the latch package from the event meant an IME
            // window popping up inside Settings cleared `specialAccessLatch` (turning a held grant back into "the
            // parent is granting it") and reset the location latch the same way. The foreground application package
            // is the one whose page is in front, so it is what the latches read.
            val latchPkg = com.familyshield.agent.receivers.AccessibilityOffPolicy.latchPackage(pkg, pkgOfEvent)
            // R2 (Antigravity's re-review): latch the grant on ENTERING a PermissionController window and clear it
            // on entering any other window, so a grant made inside that page cannot trip the gate on the content
            // change that follows the tap. The field was declared and read but never written before this.
            permissionWindowLocationActive = com.familyshield.agent.receivers.AccessibilityOffPolicy.nextLatch(
                previous = permissionWindowLocationActive,
                packageName = latchPkg,
                grantedNow = { locationGrantedNow() },
            )
            specialAccessLatch = com.familyshield.agent.receivers.AccessibilityOffPolicy.nextSpecialAccessLatch(
                previous = specialAccessLatch,
                packageName = latchPkg,
                settingsPackage = "com.android.settings",
                heldNow = { specialAccessHeld() },
            )
        }
        if (!settings.isPairedSync()) return
        // Issue #1174 (path 1): never block Settings changes while initial required grants are incomplete.
        if (requiredGrantsIncompleteForPairedDevice()) return
        if (!TamperScreenPolicy.mayHostProtectionScreen(pkg)) return
        val now = System.currentTimeMillis()
        // #533 review: suppress only while the gate is in front or still coming up — never while the guarded
        // screen is back in front of a gate that has gone away (Recents → Settings inside the old 1.5 s).
        // osra-security#7: and never while the gate shares the screen, nor for a window it was not opened over.
        val newWindow = event.eventType == AccessibilityEvent.TYPE_WINDOW_STATE_CHANGED && event.windowId != guardedWindowId
        if (GuardDebouncePolicy.suppress(
                now, lastGuardMs, GuardGateState.showing, GuardGateState.resumedSince(lastGuardMs),
                gateMultiWindow = GuardGateState.multiWindow, newWindow = newWindow,
            )
        ) return
        val root = rootInActiveWindow ?: return
        val texts = ArrayList<CharSequence?>(64)
        try {
            collectTexts(root, texts, 0)
        } finally {
            // Issue #175: the node is a native allocation on API 26–32; recycle it whether or not the
            // classification below throws.
            runCatching { root.recycle() }
        }
        val screen = TamperScreenPolicy.classify(
            packageName = pkg,
            texts = texts,
            agentLabel = getString(com.familyshield.agent.R.string.app_name),
            adminLabel = getString(com.familyshield.agent.R.string.device_admin_label),
            agentPackage = packageName,
            ourAdminActive = deviceAdmin.isAdminActive(),
            // Antigravity's Flip4 pass (#817): per package, so the keyboard's state change cannot erase Settings'.
            windowClass = pkg?.let { lastClassByPkg[it] },
            // Fable's B2 on #813: our own accessibility description, which no other app's page carries.
            agentServiceDescription = getString(com.familyshield.agent.R.string.accessibility_description),
            ourLocationActive = permissionWindowLocationActive ?: locationGrantedNow(),
            ourSpecialAccess = specialAccessLatch ?: specialAccessHeld(),
            filterProtectionActive = !consentState.isPaused() && VpnState.isEnabled(this),
            ownVpnConsentPending = VpnState.hasPendingOwnConsent(),
        )
        if (screen == TamperScreen.PRIVATE_DNS && !com.familyshield.agent.vpn.VpnState.isEnabled(this)) return // no filter to bypass yet
        if (!TamperScreenPolicy.shouldGuard(screen, pinStore.isConfigured(), TamperState.graceUntil(this), now)) return
        lastGuardMs = now
        guardedWindowId = event.windowId
        stepIn(screen, pkg, now)
    }

    /** Opens the PIN gate over [screen] and tells the parent (one alert per five-minute window). */
    private fun stepIn(screen: TamperScreen, pkg: String?, now: Long) {
        // #484 (Flip4, 1 Nov): no global Back action before the gate any more. BACK is asynchronous, so it
        // landed either on the protection screen (closing it, the gate then over the list behind it) or on
        // the gate itself (whose back is "Go back", so the child was sent Home) — three end states across
        // three runs. The gate now always opens over the screen it guards: every way out without the PIN
        // is TamperGuardActivity.goHome(), and a correct PIN returns the parent to what they opened. The
        // accessibility service is exempt from the background-launch rule, so the gate does not depend on
        // BACK having cleared the screen first.
        startActivity(
            Intent(this, TamperGuardTaskActivity::class.java)
                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP)
                .putExtra(TamperGuardActivity.EXTRA_REASON, TamperGuardActivity.REASON_SETTINGS),
        )
        // Issue #227: one alert per five-minute window. The window start and count are persisted
        // before enqueueing, so a failed POST cannot lose the attempt and the next guard retry
        // increments from the stored count instead of opening a new alert.
        val attempt = GuardAttemptWindow.record(TamperState.guardAttemptWindow(this), now, screen.name.lowercase())
        TamperState.setGuardAttemptWindow(this, attempt.state)
        TamperAlertWorker.enqueue(
            this,
            TamperAlertWorker.TYPE_GUARD_TRIGGERED,
            detail = "Screen: ${screen.name.lowercase()} in $pkg",
            windowStartMs = attempt.state.windowStartMs,
            attemptCount = attempt.state.count,
            screens = attempt.state.screens,
        )
    }

    /**
     * osra-security#7: a protection screen that shares the screen with another window (split screen, a pop-up
     * or freeform window) is covered by an accessibility overlay over its bounds, which is above every
     * application window, until it is gone or a parent PIN starts the grace window ([GuardCoverPolicy]). The gate
     * alone cannot do this: it refuses to share the screen, and One UI keeps pop-ups above it. Every visible
     * application window is judged, not only the active one: in split screen the other half holds focus.
     */
    private fun coverSharedProtectionScreens() {
        if (!settings.isPairedSync()) return removeGuardCover()
        // Issue #1174 (path 1): never cover shared protection screens while initial required grants are incomplete.
        if (requiredGrantsIncompleteForPairedDevice()) return removeGuardCover()
        val now = System.currentTimeMillis()
        val guardActive = pinStore.isConfigured() && now >= TamperState.graceUntil(this)
        if (!guardActive) return removeGuardCover()
        val all = runCatching { windows }.getOrNull().orEmpty()
        val found = ArrayList<GuardWindow>(4)
        var firstScreen = TamperScreen.NONE
        var firstPkg: String? = null
        try {
            val apps = all.filter { runCatching { it.type == AccessibilityWindowInfo.TYPE_APPLICATION }.getOrDefault(false) }
            if (apps.size < 2) return removeGuardCover()
            for (window in apps) {
                val root = runCatching { window.root }.getOrNull() ?: continue
                try {
                    val pkg = runCatching { root.packageName?.toString() }.getOrNull()
                    var screen = TamperScreen.NONE
                    if (TamperScreenPolicy.mayHostProtectionScreen(pkg)) {
                        val texts = ArrayList<CharSequence?>(64)
                        collectTexts(root, texts, 0)
                        screen = TamperScreenPolicy.classify(
                            packageName = pkg,
                            texts = texts,
                            agentLabel = getString(com.familyshield.agent.R.string.app_name),
                            adminLabel = getString(com.familyshield.agent.R.string.device_admin_label),
                            agentPackage = packageName,
                            ourAdminActive = deviceAdmin.isAdminActive(),
                            // The class of the window's own package, kept per package: the last state change may have
                            // been the soft keyboard's (Antigravity's Flip4 pass, #817), which must not erase this.
                            // `isActive` still gates it: an inactive pane does not borrow the active window's class.
                            windowClass = if (runCatching { window.isActive }.getOrDefault(false)) {
                                pkg?.let { lastClassByPkg[it] }
                            } else {
                                null
                            },
                            // R3: without this the cover path never saw the description and every split-screen
                            // pane of our accessibility page stayed unclassified.
                            agentServiceDescription = getString(com.familyshield.agent.R.string.accessibility_description),
                            ourLocationActive = permissionWindowLocationActive ?: locationGrantedNow(),
                            ourSpecialAccess = specialAccessLatch ?: specialAccessHeld(),
                            filterProtectionActive = !consentState.isPaused() && VpnState.isEnabled(this),
                            ownVpnConsentPending = VpnState.hasPendingOwnConsent(),
                        )
                        if (screen == TamperScreen.PRIVATE_DNS && !com.familyshield.agent.vpn.VpnState.isEnabled(this)) {
                            screen = TamperScreen.NONE
                        }
                    }
                    if (screen != TamperScreen.NONE && firstScreen == TamperScreen.NONE) {
                        firstScreen = screen
                        firstPkg = pkg
                    }
                    val bounds = runCatching {
                        val r = android.graphics.Rect()
                        window.getBoundsInScreen(r)
                        WindowBounds(r.left, r.top, r.right, r.bottom)
                    }.getOrNull()
                    found.add(GuardWindow(protected = screen != TamperScreen.NONE, bounds = bounds))
                } finally {
                    runCatching { root.recycle() }
                }
            }
        } finally {
            all.forEach { runCatching { it.recycle() } }
        }
        val next = GuardCoverPolicy.cover(found, guardActive)
        val previous = guardCoverBounds
        guardCover.update(next)
        guardCoverBounds = next
        if (GuardCoverPolicy.stepIn(previous, next)) {
            Log.i(TAG, "guard cover over a protection screen sharing the screen (osra-security#7)")
            lastGuardMs = now
            stepIn(firstScreen, firstPkg, now)
        }
    }

    private fun removeGuardCover() {
        if (guardCoverBounds == null) return
        guardCover.remove()
        guardCoverBounds = null
    }

    private var lastReraiseMs = 0L

    /**
     * Plan 1.3: a parent's lock/pause survives a swipe from Recents, a Home press and a reboot because
     * the overlay is re-raised the moment any other window is in front while [LockState] is active
     * (phone calls and the system UI excepted, see [LockEnforcementPolicy]).
     *
     * Issue #175: "in front" now includes a blocked app that is **visible but not active** — the
     * other half of a split screen, or a PiP video over the launcher. The retry budget bounds the
     * case where the platform keeps that window above the overlay; the overlay activities are
     * declared `resizeableActivity="false"` so the system launches them full-screen and leaves split.
     */
    private fun enforceLockState(snapshot: WindowSnapshot, fallbackPackage: String?) {
        val mode = LockState.mode(this)
        if (!LockEnforcementPolicy.isLockingMode(mode)) return
        // Issue #1183: parent-configured always-allowed apps stay usable while locked, while any
        // non-allowed app (alone or alongside an allowed app in split-screen/PiP) still raises lock.
        val alwaysAllowed = rules.cachedRules()?.alwaysAllowedApps?.toSet().orEmpty()
        var shouldRaise = LockEnforcementPolicy.shouldReraise(mode, snapshot, packageName, packageFacts, alwaysAllowed)
        // No window list from the OS (some OEMs): keep the #165 behaviour and decide from the
        // package resolved for the event, which is a hint but better than no re-raise at all.
        if (!shouldRaise && snapshot.windows.isEmpty() && snapshot.activePackage.isNullOrBlank()) {
            shouldRaise = LockEnforcementPolicy.shouldReraise(mode, fallbackPackage, packageName, packageFacts, alwaysAllowed)
        }
        if (!shouldRaise) return
        val now = System.currentTimeMillis()
        if (now - lastReraiseMs < LockEnforcementPolicy.RERAISE_DEBOUNCE_MS) return
        val signature = snapshot.signature.ifEmpty { "fallback:${fallbackPackage.orEmpty()}" }
        if (!allowOverlay(lockRetryBudget, signature, snapshot.layout, "lock")) return
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
            try {
                collectTexts(child, out, depth + 1)
            } finally {
                runCatching { child.recycle() }
            }
        }
    }

    private fun collapseShadeAfterRingEnded() {
        collapseShadeOnRingClosed(
            isRunning = isRunning,
            locked = LockState.isActive(this),
            lastSystemUiClass = lastClassByPkg[ShadePolicy.SHADE_PACKAGE],
            apiLevel = Build.VERSION.SDK_INT,
            callRinging = calls.isRinging(),
        ) {
            performGlobalAction(GLOBAL_ACTION_DISMISS_NOTIFICATION_SHADE)
            scheduleShadeRecheck(delayMs = SHADE_RECHECK_MS, slot = ShadePulse.STATE)
            scheduleShadeRecheck(delayMs = SHADE_LATE_RECHECK_MS, slot = ShadePulse.LATE)
        }
    }

    override fun onInterrupt() = Unit

    companion object {
        private const val TAG = "AccessibilityMonitor"

        internal const val SHADE_RECHECK_MS = 250L
        internal const val SHADE_LATE_RECHECK_MS = 700L
        internal const val SHADE_CONTENT_RECHECK_MS = 300L

        internal fun isNonEssentialBlocked(isEssential: Boolean, lockedOrRuleBlocked: Boolean): Boolean =
            !isEssential && lockedOrRuleBlocked

        internal fun bindRingWindowCallbacks(
            scheduler: IncomingRingWindow.Scheduler,
            onClosed: () -> Unit,
        ) {
            IncomingRingWindow.bindCallbacks(onClosed = onClosed, expiryScheduler = scheduler)
        }

        internal fun collapseShadeOnRingClosed(
            isRunning: Boolean,
            locked: Boolean,
            lastSystemUiClass: String?,
            apiLevel: Int,
            callRinging: Boolean,
            onCollapse: () -> Unit,
        ) {
            if (!isRunning) return
            if (ShadePolicy.shouldCollapse(
                    locked = locked,
                    packageName = ShadePolicy.SHADE_PACKAGE,
                    className = lastSystemUiClass,
                    apiLevel = apiLevel,
                    callRinging = callRinging,
                )
            ) {
                onCollapse()
            }
        }

        /**
         * Issue #231 review: true while the system holds this service bound, set from
         * [onServiceConnected] and cleared when it unbinds. `EnforceabilityPolicy` uses it for the
         * `lock`/`pause` accessibility path: the bound service is exempt from the background-activity
         * launch rule and re-raises the overlay, whereas `Settings.Secure` only says the user enabled
         * it. Same-process state, so it describes the process that is about to dispatch the command.
         */
        private val _runningState = MutableStateFlow(false)

        /**
         * Live state of [isRunning] so foreground onboarding screens waiting for the OS to finish
         * binding after the parent returns from Settings advance immediately (#1131 review).
         */
        val runningState: StateFlow<Boolean> = _runningState.asStateFlow()

        var isRunning: Boolean
            get() = _runningState.value
            internal set(value) {
                _runningState.value = value
            }

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
            isServiceRunning -> null
            // Issue #472: the pair state is an input to the shared rule, not a second guard here.
            else -> LocationStartPolicy.decide(
                isPaired = paired,
                hasFineLocation = hasFineLocation,
                hasCoarseLocation = hasCoarseLocation,
                hasBackgroundLocation = hasBackgroundLocation,
                apiLevel = apiLevel,
            )
        }
    }
}
