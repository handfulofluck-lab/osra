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
import android.view.accessibility.AccessibilityNodeInfo
import android.view.accessibility.AccessibilityWindowInfo
import androidx.core.content.ContextCompat
import com.familyshield.agent.data.AgentSettings
import com.familyshield.agent.data.ConsentState
import com.familyshield.agent.data.RuleRepository
import com.familyshield.agent.enforcement.AppBlocker
import com.familyshield.agent.enforcement.BlockRaisePolicy
import com.familyshield.agent.enforcement.BypassAlertFloor
import com.familyshield.agent.enforcement.EssentialPackages
import com.familyshield.agent.enforcement.LockEnforcementPolicy
import com.familyshield.agent.enforcement.LockState
import com.familyshield.agent.enforcement.OverlayRetryBudget
import com.familyshield.agent.enforcement.PackageFacts
import com.familyshield.agent.enforcement.RetryDecision
import com.familyshield.agent.enforcement.VisibleBlockStep
import com.familyshield.agent.enforcement.VisibleWindow
import com.familyshield.agent.enforcement.WindowBounds
import com.familyshield.agent.enforcement.WindowLayout
import com.familyshield.agent.enforcement.WindowSnapshot
import com.familyshield.agent.security.GuardAttemptWindow
import com.familyshield.agent.security.ParentPinStore
import com.familyshield.agent.security.TamperAlertWorker
import com.familyshield.agent.security.TamperGuardActivity
import com.familyshield.agent.security.TamperScreen
import com.familyshield.agent.security.TamperScreenPolicy
import com.familyshield.agent.security.TamperState
import com.familyshield.agent.social.SocialCapture
import com.familyshield.agent.telemetry.UsageReporter
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

    /** Issue #83 review F1 / #165: what the OS says a package is, shared with [AppBlocker]'s overlay guard. */
    @Inject lateinit var packageFacts: PackageFacts

    private var lastLocationCheckMs = 0L
    private var lastGuardMs = 0L

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

    /** Issue #460: the fallback that raises the deferred block screen when no launcher event arrives. */
    private val main = android.os.Handler(android.os.Looper.getMainLooper())
    private val deferredRaise = Runnable { raiseDeferredIfDue() }

    /** Issue #444: a blocked app's calls are declined, covered, hung up or reported ([CallBlockPolicy]). */
    private val calls by lazy {
        CallEnforcer(
            this,
            isBlocked = { rules.evaluate(it) != RuleRepository.Decision.ALLOW },
            isEssential = { EssentialPackages.isEssential(it, packageFacts) },
            floor = bypassFloor,
        )
    }

    /** Issue #444 C4: a rule sync may have just blocked an app that is playing; the check runs on the main thread. */
    private val rulesChanged: () -> Unit = {
        android.os.Handler(android.os.Looper.getMainLooper()).post { media.onRulesChanged() }
    }

    /** Issue #444 C4: a blocked app's media audio is paused, however it was started ([MediaBlockPolicy]). */
    private val media by lazy {
        MediaEnforcer(this, isBlocked = { rules.evaluate(it) != RuleRepository.Decision.ALLOW })
    }

    /** Issue #132: log a refused start once per reason, not once per 60 s accessibility event. */
    private var loggedStartDecision: LocationStartPolicy.Decision? = null

    /** Issue #83 review F1: the dialer/system flags are cached for the hot path, so refresh on package changes. */
    private val packageChangeReceiver = object : BroadcastReceiver() {
        override fun onReceive(context: android.content.Context?, intent: Intent?) = packageFacts.refresh()
    }

    override fun onServiceConnected() {
        super.onServiceConnected()
        // Issue #231 review: this callback is the system telling us it has bound the service, so it
        // is the authoritative "accessibility is running" for EnforceabilityPolicy — not the
        // ENABLED_ACCESSIBILITY_SERVICES setting, which stays true while the service is not alive.
        isRunning = true
        val filter = IntentFilter().apply {
            addAction(Intent.ACTION_PACKAGE_ADDED)
            addAction(Intent.ACTION_PACKAGE_REPLACED)
            addAction(Intent.ACTION_PACKAGE_REMOVED)
            addDataScheme("package")
        }
        runCatching { registerReceiver(packageChangeReceiver, filter) }
        calls.onConnected()
        media.onConnected()
        rules.addRulesChangedListener(rulesChanged)
    }

    override fun onUnbind(intent: Intent?): Boolean {
        // Called when the system is about to unbind (the user turned the service off, or it was
        // replaced); onDestroy follows, but the command poll must see the service as gone at once.
        isRunning = false
        return super.onUnbind(intent)
    }

    override fun onDestroy() {
        isRunning = false
        calls.onDestroy()
        media.onDestroy()
        rules.removeRulesChangedListener(rulesChanged)
        pipCover.remove()
        // #460 review: a deferred raise posted inside the fallback window must not fire after the
        // service is gone — the child turning accessibility off is exactly when that window exists.
        cancelDeferredRaise()
        runCatching { unregisterReceiver(packageChangeReceiver) }
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
        val eventPkg = event?.packageName?.toString() ?: return
        calls.onEvent()
        // Issue #284: our own block screen is in front and this stream never records our package, so
        // the blocked app's interval would stay open and the next real event would charge it the stay.
        if (eventPkg == packageName) {
            usage.recordOwnWindow(System.currentTimeMillis())
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
        // The lock is the safe direction: when the window in front cannot be named, the event package
        // is the only hint and the overlay must still come back (LockEnforcementPolicy decides).
        enforceLockState(snapshot, foreground ?: eventPkg)
        // ADR-0008 §3: consent withdrawn — the service keeps polling (to learn about a re-grant) but
        // records, captures and enforces nothing.
        if (consentState.isPaused()) {
            pipCover.remove()
            // #460 review: consent withdrawn inside the fallback window must not still show a block
            // screen — ADR-0008 §3 says a paused agent records, captures and enforces nothing.
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

    /**
     * Issue #460: show the screen a blocked package gets, once it is time to show it.
     */
    private fun raiseBlockOrTimeLimit(pkg: String, blocked: Boolean) {
        // The policy owns the spacing (1 s); AppBlocker's own 2 s debounce would halve it.
        blocker.clearDebounce(pkg)
        media.onRaise(pkg) // #444 C4: pause the blocked app's media when its screen goes up
        if (blocked) blocker.showBlockScreen(pkg) else blocker.showTimeLimitScreen(pkg)
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
        raiseBlockOrTimeLimit(deferred.pkg, deferred.blocked)
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
        if (consentState.isPaused()) {
            cancelDeferredRaise()
            return
        }
        val deferred = blockRaisePolicy.launcherFront(
            launcherFront = true,
            nowMs = System.currentTimeMillis(),
        ) ?: return
        raiseBlockOrTimeLimit(deferred.pkg, deferred.blocked)
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
        val found = VisibleBlockStep.decide(
            snapshot,
            active,
            evaluate = rules::evaluate,
            isEssential = { EssentialPackages.isEssential(it, packageFacts) },
            policy = blockRaisePolicy,
            nowMs = System.currentTimeMillis(),
        )
        if (found == null) {
            pipCover.update(null)
            return
        }
        val (pkg, decision, step) = found
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
                blockRaisePolicy.noteHomeSent(pkg, blocked, System.currentTimeMillis())
                main.removeCallbacks(deferredRaise)
                main.postDelayed(deferredRaise, BlockRaisePolicy.DEFAULT_HOME_FALLBACK_MS)
            } else {
                raiseBlockOrTimeLimit(pkg, blocked)
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
        if (!settings.isPairedSync()) return
        val now = System.currentTimeMillis()
        if (now - lastGuardMs < 1_500L) return
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
        // Issue #227: one alert per five-minute window. The window start and count are persisted
        // before enqueueing, so a failed POST cannot lose the attempt and the next guard retry
        // increments from the stored count instead of opening a new alert.
        val attempt = GuardAttemptWindow.record(TamperState.guardAttemptWindow(this), now)
        TamperState.setGuardAttemptWindow(this, attempt.state)
        TamperAlertWorker.enqueue(
            this,
            TamperAlertWorker.TYPE_GUARD_TRIGGERED,
            detail = "Screen: ${screen.name.lowercase()} in $pkg",
            windowStartMs = attempt.state.windowStartMs,
            attemptCount = attempt.state.count,
        )
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
        var shouldRaise = LockEnforcementPolicy.shouldReraise(mode, snapshot, packageName, packageFacts)
        // No window list from the OS (some OEMs): keep the #165 behaviour and decide from the
        // package resolved for the event, which is a hint but better than no re-raise at all.
        if (!shouldRaise && snapshot.windows.isEmpty() && snapshot.activePackage.isNullOrBlank()) {
            shouldRaise = LockEnforcementPolicy.shouldReraise(mode, fallbackPackage, packageName, packageFacts)
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

    override fun onInterrupt() = Unit

    companion object {
        private const val TAG = "AccessibilityMonitor"

        /**
         * Issue #231 review: true while the system holds this service bound, set from
         * [onServiceConnected] and cleared when it unbinds. `EnforceabilityPolicy` uses it for the
         * `lock`/`pause` accessibility path: the bound service is exempt from the background-activity
         * launch rule and re-raises the overlay, whereas `Settings.Secure` only says the user enabled
         * it. Same-process state, so it describes the process that is about to dispatch the command.
         */
        @Volatile
        var isRunning: Boolean = false
            internal set

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
