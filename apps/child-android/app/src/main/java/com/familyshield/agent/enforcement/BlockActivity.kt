package com.familyshield.agent.enforcement

import com.familyshield.agent.R
import com.familyshield.agent.data.WindowKind
import com.familyshield.agent.data.WindowReason

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.os.Bundle
import android.net.VpnService
import androidx.activity.result.contract.ActivityResultContracts
import androidx.activity.ComponentActivity
import androidx.activity.OnBackPressedCallback
import androidx.activity.compose.setContent
import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.safeDrawing
import androidx.compose.foundation.layout.windowInsetsPadding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.Button
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.SideEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.key
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.core.content.ContextCompat
import androidx.core.view.WindowCompat
import com.familyshield.agent.data.AgentSettings
import com.familyshield.agent.data.RuleRepository
import com.familyshield.agent.network.ApiService
import com.familyshield.agent.network.DeviceUnlinker
import com.familyshield.agent.network.dto.AlertDto
import com.familyshield.agent.sos.SosActivity
import com.familyshield.agent.ui.block.BlockedAppCopy
import com.familyshield.agent.ui.block.BlockedAppScreen
import com.familyshield.agent.ui.block.StillOpenAppUi
import com.familyshield.agent.ui.theme.ChildUxFlags
import com.familyshield.agent.ui.theme.OsraTheme
import com.familyshield.agent.vpn.FilterVpnService
import com.familyshield.agent.vpn.VpnState
import java.time.ZonedDateTime
import dagger.hilt.android.AndroidEntryPoint
import javax.inject.Inject
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.launch

/**
 * Full-screen overlay shown when the parent blocks an app or its daily limit is reached.
 * "Request access" POSTs an app_blocked alert to /v1/alerts/internal (HMAC-signed).
 * Cannot be dismissed to reveal the blocked app (AND-04): Back and "Exit to Home screen"
 * navigate directly to the home launcher and clear the app debounce.
 *
 * Issue #671: it is also the root of a task of its own (`AndroidManifest.xml`), so closing it returns to
 * what was underneath rather than to another agent screen, and it takes itself down on resume or stop
 * once the rules no longer block its app ([closeIfNoLongerBlocked]).
 */
@AndroidEntryPoint
class BlockActivity : ComponentActivity() {

    @Inject lateinit var api: ApiService
    @Inject lateinit var settings: AgentSettings
    @Inject lateinit var appBlocker: AppBlocker
    @Inject lateinit var rules: RuleRepository
    // S1 (osra-security#39): the same pause the filter service honours. Without it a blocked app tapped
    // while consent is withdrawn still increments the persisted counter and posts a row.
    @Inject lateinit var consent: com.familyshield.agent.data.ConsentState

    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)

    // Issue #217: `launchMode="singleTask"` reuses this instance, so the package cannot be read once in
    // onCreate. These are Compose state, replaced by onNewIntent through [session]; the screen, the
    // label and both actions then follow the block that is actually in front.
    private var request by mutableStateOf(BlockRequest())
    private var appLabel by mutableStateOf("")
    private val session = BlockSession(
        labelOf = { pkg -> applicationLabel(pkg) },
        onChanged = { newRequest, newLabel ->
            request = newRequest
            appLabel = newLabel
        },
    )

    private val vpnConsent = registerForActivityResult(ActivityResultContracts.StartActivityForResult()) { result ->
        VpnState.endOwnConsent()
        if (result.resultCode == RESULT_OK && VpnState.isFilterLost(this, settings, consent)) {
            FilterVpnService.start(this)
        }
    }

    private fun reconnectFilter() {
        if (!VpnState.isFilterLost(this, settings, consent)) {
            finish()
            return
        }
        val prompt = VpnService.prepare(this)
        if (prompt == null) {
            FilterVpnService.start(this)
        } else {
            VpnState.beginOwnConsent()
            runCatching { vpnConsent.launch(prompt) }.onFailure { VpnState.endOwnConsent() }
        }
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        @Suppress("DEPRECATION")
        // Issue #87: same rule as the lock overlay - never over the keyguard. A block screen that covers
        // the bouncer hides the owner's PIN pad, and the blocked app is not in use while the phone is
        // locked anyway. turnScreenOn stays so a time-limit screen still wakes a dimmed device.
        window.addFlags(android.view.WindowManager.LayoutParams.FLAG_TURN_SCREEN_ON)
        WindowCompat.setDecorFitsSystemWindows(window, false)

        val keyguardLocked = getSystemService(android.app.KeyguardManager::class.java)?.isKeyguardLocked == true
        if (KeyguardPolicy.shouldDeferToKeyguard("blocked", keyguardLocked)) {
            finish()
            return
        }

        onBackPressedDispatcher.addCallback(this, object : OnBackPressedCallback(true) {
            override fun handleOnBackPressed() {
                goHome()
            }
        })

        applyIntent(intent)
        // #830: every block the child meets is reported, not only the "Request access" tap, so the parent
        // sees "tried to open X" with a growing attempt count.
        reportBlockedAttempt(request.packageId, request.reason)

        setContent {
            val useC02 = request.reason != REASON_FILTER_LOST && ChildUxFlags.c02BlockedScreenEnabled
            val darkTheme = isSystemInDarkTheme()
            SideEffect {
                val controller = WindowCompat.getInsetsController(window, window.decorView)
                val lightIconsBackground = useC02 && !darkTheme
                controller.isAppearanceLightStatusBars = lightIconsBackground
                controller.isAppearanceLightNavigationBars = lightIconsBackground
            }
            if (useC02) {
                OsraTheme.OsraTheme(darkTheme = darkTheme) {
                    key(request.packageId, request.reason) {
                        val explanation = BlockExplainPolicy.explain(
                            ruleSet = rules.cachedRules(),
                            packageId = request.packageId,
                            now = ZonedDateTime.now(),
                            minutesUsedToday = rules.minutesSnapshot(),
                            blocklist = rules.blocklistSnapshot(),
                            pausedInternet = rules.isInternetPaused(),
                            bonusMinutes = rules.bonusMinutesTodaySnapshot(),
                            declaresVpnService = rules.declaresVpnServiceSnapshot(request.packageId),
                            fallbackReason = request.reason,
                            fallbackWindow = request.window,
                        )
                        val copy = buildC02Copy(appLabel, explanation)
                        BlockedAppScreen(
                            copy = copy,
                            onPrimaryRequest = {
                                sendChildRequest(session.requestAccessPackage(), explanation, request.reason)
                            },
                            onOpenAllowedApp = { pkg -> openStillOpenTarget(pkg) },
                            onCallParent = { openDialer() },
                            onSendSos = { openSos() },
                            onExitHome = { goHome() },
                        )
                    }
                }
            } else {
                MaterialTheme {
                    Surface(modifier = Modifier.fillMaxSize(), color = Color(0xFF131318)) {
                        // Keyed on the package so the "Request sent" state belongs to one app, not to the
                        // instance: a second block starts with a fresh button.
                        key(request.packageId, request.reason) {
                            if (request.reason == REASON_FILTER_LOST) {
                                FilterRecoveryScreen(onReconnect = ::reconnectFilter, onExit = ::goHome)
                            } else BlockScreen(
                                appLabel = appLabel,
                                timeLimit = request.timeLimit,
                                window = request.window,
                                onRequestAccess = { requestAccess(session.requestAccessPackage(), request.reason) },
                                onExit = { goHome() },
                            )
                        }
                    }
                }
            }
        }
    }

    /**
     * Issue #488: a block screen left open across an unlink kept saying the app was blocked, on a phone no
     * family manages any more. Two paths, the #479 shape:
     * - **while the screen is started** this receiver fires on [DeviceUnlinker.ACTION_UNLINKED];
     * - **on return from the background** [onResume] finds the phone unpaired, because the receiver is
     *   unregistered in `onStop` and would have missed the broadcast.
     */
    private val unlinkedReceiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context?, intent: Intent?) {
            when (intent?.action) {
                DeviceUnlinker.ACTION_UNLINKED -> if (!settings.isPairedSync()) finish()
                VpnState.ACTION_FILTER_LOSS_CHANGED ->
                    if (request.reason == REASON_FILTER_LOST) closeIfNoLongerBlocked()
            }
        }
    }

    override fun onStart() {
        super.onStart()
        ContextCompat.registerReceiver(
            this,
            unlinkedReceiver,
            IntentFilter(DeviceUnlinker.ACTION_UNLINKED).apply { addAction(VpnState.ACTION_FILTER_LOSS_CHANGED) },
            ContextCompat.RECEIVER_NOT_EXPORTED,
        )
    }

    override fun onStop() {
        runCatching { unregisterReceiver(unlinkedReceiver) }
        // Issue #671: a screen the child left with Home must not lie in wait behind the next agent
        // screen. If the block has been lifted by now, it goes here rather than when it is uncovered.
        closeIfNoLongerBlocked()
        super.onStop()
    }

    override fun onResume() {
        super.onResume()
        // Issue #488: the unlink happened while this screen was in the background.
        if (!settings.isPairedSync()) finish()
        // Issue #671: the screen may be coming back from the ring, or from the keyguard. If the rules no
        // longer block its app, it must come down now — not show a block that was lifted minutes ago.
        closeIfNoLongerBlocked()
    }

    /**
     * Issue #671 (Flip4 scenario run 1, #665): this screen used to stay up until the child chose "Exit to
     * Home screen", so one left with Home was uncovered by whatever agent screen closed next — the ring
     * at 19:10Z, or the bouncer after an unlock — while nothing was blocked any more.
     *
     * The question is the one that raised the screen: [RuleRepository.verdict] for the package on
     * screen, so an unknown rule set (paired, nothing cached) and a snapshot that has not caught up both
     * answer BLOCK and the screen **stays**. [BlockRecheckPolicy] holds that table and the reason each
     * row is safe; a re-check failing open would unblock an app the parent blocked, which is worse than
     * the bug this closes.
     */
    private fun closeIfNoLongerBlocked() {
        if (request.reason == REASON_FILTER_LOST) {
            if (!VpnState.isFilterLost(this, settings, consent)) finish()
            return
        }
        val pkg = session.request.packageId
        val decision = rules.verdict(pkg).decision
        if (BlockRecheckPolicy.decide(pkg, decision) == BlockRecheckPolicy.Action.FINISH) {
            finish()
        }
    }

    /**
     * Issue #217: a second block reuses this `singleTask` instance. Without this override the screen kept
     * the first app's package, so "Request access" asked the parent to unblock the wrong app.
     */
    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        applyIntent(intent)
        // Hydrogen's #836 blocker: a `singleTask` reuse skipped the attempt report, which runs only in
        // onCreate — so a second block of the same or another app never incremented the parent's row.
        // `session.apply` above has already replaced `request`, so this reports the block in front.
        reportBlockedAttempt(request.packageId, request.reason)
        if (request.reason == REASON_FILTER_LOST) closeIfNoLongerBlocked()
    }

    private fun applyIntent(intent: Intent) {
        session.apply(
            intent.getStringExtra(EXTRA_PACKAGE),
            intent.getStringExtra(EXTRA_REASON),
            windowFrom(intent),
        )
    }

    /** The app's user-facing name, or null when the OS cannot resolve it (the package id is then shown). */
    private fun applicationLabel(pkg: String): String? = runCatching {
        packageManager.getApplicationLabel(packageManager.getApplicationInfo(pkg, 0)).toString()
    }.getOrNull()

    private fun goHome() {
        session.clearDebouncePackage()?.let { pkg ->
            runCatching { appBlocker.clearDebounce(pkg) }
        }
        val homeIntent = Intent(Intent.ACTION_MAIN).apply {
            addCategory(Intent.CATEGORY_HOME)
            flags = Intent.FLAG_ACTIVITY_NEW_TASK
        }
        startActivity(homeIntent)
        finish()
    }

    /**
     * #830: one grouped `app_blocked` row per app per UTC day. The count is monotonic
     * ([AttemptCounter]); the server updates the existing row only when the count is higher and never
     * pushes again, so a child tapping a blocked app ten times reads "10 attempts" and one notification.
     */
    private fun reportBlockedAttempt(pkg: String, reason: String) {
        // Recovery has one incident alert from the VPN service, independent of app attempts.
        // Issue #1174 / Ahmed acceptance (7200575366): no app_blocked alert before initial setup completes.
        if (reason == REASON_FILTER_LOST || consent.isPaused()) return
        if (settings.isPairedSync()) {
            val deviceId = settings.deviceIdSync()
            com.familyshield.agent.setup.SetupCompletionStore.seedUpgradeLatchIfNeeded(this, deviceId)
            if (!com.familyshield.agent.setup.SetupCompletionStore.isCompletedForDevice(this, deviceId)) return
        }
        val day = java.time.LocalDate.now(java.time.ZoneOffset.UTC).toString()
        val attempts = AttemptCounter.next(this, "app", pkg, day)
        val appLabelSnapshot = appLabel
        scope.launch {
            runCatching {
                api.postInternalAlert(
                    AlertDto(
                        childId = settings.childId(),
                        deviceId = settings.deviceId(),
                        severity = "info",
                        category = "app_blocked",
                        title = "Blocked app opened",
                        body = "Your child tried to open a blocked app.",
                        metadata = mapOf("packageId" to pkg, "reason" to reason, "appName" to appLabelSnapshot),
                        dedupeKey = AlertKeys.blockedApp(pkg, day),
                        attemptCount = attempts,
                    ),
                )
            }
        }
    }

    /** POSTs an app_blocked alert for the blocked package; failures are swallowed (best effort). */
    private fun requestAccess(pkg: String, reason: String) {
        val appLabelSnapshot = appLabel
        scope.launch {
            runCatching {
                api.postInternalAlert(
                    AlertDto(
                        childId = settings.childId(),
                        deviceId = settings.deviceId(),
                        severity = "info",
                        category = "app_blocked",
                        title = "Access requested",
                        body = "Child requested access to $pkg",
                        metadata = mapOf(
                            "packageId" to pkg,
                            "reason" to reason,
                            "appName" to appLabelSnapshot,
                            "requestType" to "access",
                        ),
                    ),
                )
            }
        }
    }

    /** C-02 (#1179, G2/G3, #1116): posts either a daily-limit time request (`requestType = "time"`) or an app access request (`requestType = "access"`), carrying the snapshotted `appName`. */
    private fun sendChildRequest(pkg: String, explanation: BlockExplanation, fallbackReason: String) {
        val appLabelSnapshot = appLabel
        val payload = BlockExplainPolicy.buildRequestPayload(
            packageId = pkg,
            explanation = explanation,
            fallbackReason = fallbackReason,
            requestedMinutes = 15,
            appName = appLabelSnapshot,
        )
        scope.launch {
            runCatching {
                api.postInternalAlert(
                    AlertDto(
                        childId = settings.childId(),
                        deviceId = settings.deviceId(),
                        severity = "info",
                        category = "app_blocked",
                        title = payload.title,
                        body = payload.body,
                        metadata = payload.metadata,
                    ),
                )
            }
        }
    }

    private fun openStillOpenTarget(pkg: String?) {
        if (pkg.isNullOrBlank()) {
            openDialer()
            return
        }
        val launch = packageManager.getLaunchIntentForPackage(pkg)?.apply {
            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        }
        if (launch != null && runCatching { startActivity(launch) }.isSuccess) {
            finish()
        }
    }

    private fun openDialer() {
        runCatching {
            startActivity(Intent(Intent.ACTION_DIAL).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
        }
    }

    private fun openSos() {
        runCatching {
            startActivity(Intent(this, SosActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
        }
    }

    private fun formatDurationWords(totalMinutes: Int): String {
        val safe = totalMinutes.coerceAtLeast(0)
        val hours = safe / 60
        val mins = safe % 60
        return when {
            hours > 0 && mins > 0 -> getString(
                R.string.c02_hours_and_minutes,
                resources.getQuantityString(R.plurals.c02_hours, hours, hours),
                resources.getQuantityString(R.plurals.c02_minutes, mins, mins),
            )
            hours > 0 -> resources.getQuantityString(R.plurals.c02_hours, hours, hours)
            else -> resources.getQuantityString(R.plurals.c02_minutes, mins, mins)
        }
    }

    private fun buildC02Copy(label: String, explanation: BlockExplanation): BlockedAppCopy {
        val displayApp = label.ifBlank { request.packageId }
        val isolatedApp = BlockExplainPolicy.ltrIsolate(displayApp)
        val monogram = displayApp.trim().firstOrNull()?.uppercaseChar()?.toString() ?: "O"

        val reasonPill = when (explanation.cause) {
            BlockCause.DAILY_LIMIT -> getString(R.string.c02_reason_daily_limit)
            BlockCause.APP_LIMIT -> getString(R.string.c02_reason_app_limit)
            BlockCause.BEDTIME -> getString(R.string.c02_reason_bedtime)
            BlockCause.SCHOOL -> getString(R.string.c02_reason_school)
            BlockCause.ROUTINE -> explanation.routineName
                ?.let { BlockExplainPolicy.firstStrongIsolate(it) }
                ?: getString(R.string.c02_reason_blocked)
            BlockCause.PAUSED_INTERNET -> getString(R.string.c02_reason_paused_internet)
            BlockCause.APP_BLOCKED -> getString(R.string.c02_reason_blocked)
        }

        val subtitle = when (explanation.cause) {
            BlockCause.DAILY_LIMIT -> {
                val used = explanation.usedMinutes
                val limit = explanation.limitMinutes
                if (used != null && limit != null && limit > 0) {
                    getString(R.string.c02_subtitle_used_of, formatDurationWords(used), formatDurationWords(limit))
                } else {
                    getString(R.string.c02_subtitle_daily_limit)
                }
            }
            BlockCause.APP_LIMIT -> {
                val used = explanation.usedMinutes
                val limit = explanation.limitMinutes
                if (used != null && limit != null && limit > 0) {
                    getString(R.string.c02_subtitle_used_of, formatDurationWords(used), formatDurationWords(limit))
                } else {
                    getString(R.string.c02_subtitle_app_limit, isolatedApp)
                }
            }
            BlockCause.BEDTIME -> getString(R.string.c02_subtitle_bedtime)
            BlockCause.SCHOOL -> getString(R.string.c02_subtitle_school)
            BlockCause.ROUTINE -> explanation.routineName?.let {
                getString(R.string.c02_subtitle_routine, BlockExplainPolicy.firstStrongIsolate(it))
            } ?: getString(R.string.c02_subtitle_blocked)
            BlockCause.PAUSED_INTERNET -> getString(R.string.c02_subtitle_paused_internet)
            BlockCause.APP_BLOCKED -> getString(R.string.c02_subtitle_blocked)
        }

        val backAtValue = explanation.backAtTime?.let { hhMm ->
            val isolatedTime = BlockExplainPolicy.ltrIsolate(hhMm)
            if (explanation.backAtTomorrow) {
                getString(R.string.c02_back_at_tomorrow, isolatedTime)
            } else {
                getString(R.string.c02_back_at_today, isolatedTime)
            }
        }

        val alwaysOpenBadge = getString(R.string.c02_always_open_pill)
        val stillOpenRows = buildList {
            for (pkg in explanation.stillOpenPackages) {
                val resolved = applicationLabel(pkg)?.takeIf { it.isNotBlank() } ?: continue
                add(
                    StillOpenAppUi(
                        packageId = pkg,
                        label = BlockExplainPolicy.ltrIsolate(resolved),
                        badge = alwaysOpenBadge,
                    ),
                )
            }
            add(
                StillOpenAppUi(
                    packageId = null,
                    label = getString(R.string.c02_messages_and_calls),
                    badge = alwaysOpenBadge,
                ),
            )
        }

        val primaryLabel = if (explanation.canAskForMoreTime) {
            getString(R.string.c02_ask_more_time_15)
        } else {
            getString(R.string.c02_ask_to_open, isolatedApp)
        }

        val summary = BlockExplainPolicy.rulesSummary(
            ruleSet = rules.cachedRules(),
            now = ZonedDateTime.now(),
            minutesUsedToday = rules.minutesSnapshot(),
            bonusMinutes = rules.bonusMinutesTodaySnapshot(),
        )
        val rulesLines = buildList {
            summary.dailyLimitMinutes?.let { limit ->
                add(
                    getString(
                        R.string.c02_rules_daily_limit,
                        formatDurationWords(summary.dailyUsedMinutes),
                        formatDurationWords(limit),
                    ),
                )
            }
            summary.bedtimeWindow?.let { (start, end) ->
                add(
                    getString(
                        R.string.c02_rules_bedtime,
                        BlockExplainPolicy.ltrRange(start, end),
                    ),
                )
            }
            summary.schoolWindow?.let { (start, end) ->
                add(
                    getString(
                        R.string.c02_rules_school,
                        BlockExplainPolicy.ltrRange(start, end),
                    ),
                )
            }
            if (summary.routineNames.isNotEmpty()) {
                val joined = summary.routineNames.joinToString(", ") { BlockExplainPolicy.firstStrongIsolate(it) }
                add(getString(R.string.c02_rules_routines, joined))
            }
        }

        return BlockedAppCopy(
            brandLabel = getString(R.string.app_name),
            reasonPill = reasonPill,
            monogram = monogram,
            headline = getString(R.string.c02_paused_title, isolatedApp),
            subtitle = subtitle,
            backAgainLabel = getString(R.string.c02_back_again_label),
            backAtValue = backAtValue,
            stillOpenLabel = getString(R.string.c02_still_open_label),
            stillOpenApps = stillOpenRows,
            primaryRequestLabel = primaryLabel,
            requestSentTitle = getString(R.string.block_request_sent),
            requestWaitingLine = getString(R.string.c02_waiting_reply),
            callParentLabel = getString(R.string.c02_call_parent),
            seeMyRulesLabel = getString(R.string.c02_see_my_rules),
            sendSosLabel = getString(R.string.c02_send_sos_row),
            exitHomeLabel = getString(R.string.block_exit_home),
            emergencyNote = getString(R.string.c02_emergency_note),
            rulesSheetTitle = getString(R.string.c02_rules_sheet_title),
            rulesSheetLines = rulesLines,
            rulesSheetEmpty = getString(R.string.c02_rules_none),
            rulesSheetClose = getString(R.string.c02_rules_close),
        )
    }

    companion object {
        /** Intent extra: the package that was blocked. */
        const val EXTRA_PACKAGE: String = "package"

        /** Intent extra: block reason (REASON_BLOCKED or REASON_TIME_LIMIT). */
        const val EXTRA_REASON: String = "reason"

        /**
         * Issue #473: the window that fired, when there is one. Absent means the block came from the
         * app's own rule (or a pause, or the blocklist) and the screen keeps its existing copy.
         */
        const val EXTRA_WINDOW_KIND: String = "window_kind"
        const val EXTRA_WINDOW_NAME: String = "window_name"
        const val EXTRA_WINDOW_ENDS: String = "window_ends"

        /** Reason value: the app is blocked by a parent rule. */
        const val REASON_BLOCKED: String = "blocked"

        /** Reason value: the app's daily time limit is used up. */
        const val REASON_TIME_LIMIT: String = "time_limit"
        const val REASON_FILTER_LOST: String = "filter_lost"
    }
}

/**
 * Issue #473: the window the launching intent named, or null when it named none.
 *
 * A kind the app does not know (a newer agent's, a typo) reads as null, so the screen shows today's copy
 * rather than half a sentence. The ends time is required for the same reason: a window with no end cannot
 * be described.
 */
private fun windowFrom(intent: Intent): WindowReason? {
    val kind = intent.getStringExtra(BlockActivity.EXTRA_WINDOW_KIND) ?: return null
    val ends = intent.getStringExtra(BlockActivity.EXTRA_WINDOW_ENDS) ?: return null
    val parsed = runCatching { WindowKind.valueOf(kind) }.getOrNull() ?: return null
    return WindowReason(parsed, intent.getStringExtra(BlockActivity.EXTRA_WINDOW_NAME), ends)
}

@Composable
private fun FilterRecoveryScreen(onReconnect: () -> Unit, onExit: () -> Unit) {
    BoxWithConstraints(Modifier.fillMaxSize().windowInsetsPadding(WindowInsets.safeDrawing)) {
        val viewportHeight = maxHeight
        Column(
            modifier = Modifier.fillMaxWidth()
                .verticalScroll(rememberScrollState())
                .heightIn(min = viewportHeight)
                .padding(32.dp),
            verticalArrangement = Arrangement.spacedBy(24.dp, Alignment.CenterVertically),
            horizontalAlignment = Alignment.CenterHorizontally,
        ) {
            Text(
                text = stringResource(R.string.setup_web_filter_disconnected),
                style = MaterialTheme.typography.headlineMedium,
                color = Color.White,
                textAlign = TextAlign.Center,
            )
            Button(onClick = onReconnect) {
                Text(stringResource(R.string.setup_web_filter_reconnect))
            }
            TextButton(onClick = onExit) {
                Text(stringResource(R.string.block_exit_home), color = Color.White)
            }
        }
    }
}

@Composable
private fun BlockScreen(
    appLabel: String,
    timeLimit: Boolean,
    window: WindowReason?,
    onRequestAccess: () -> Unit,
    onExit: () -> Unit,
) {
    var sent by remember { mutableStateOf(false) }
    // #489: at targetSdk 35 the screen is drawn edge to edge, so in landscape the title sat under the
    // status bar and the cutout. The root keeps its 32 dp and adds whatever the system bars take.
    Column(
        modifier = Modifier.fillMaxSize().windowInsetsPadding(WindowInsets.safeDrawing).padding(32.dp),
        verticalArrangement = Arrangement.Center,
        horizontalAlignment = Alignment.CenterHorizontally,
    ) {
        Text(
            text = stringResource(
                if (timeLimit) R.string.block_title_time_limit else R.string.block_title_blocked,
            ),
            style = MaterialTheme.typography.headlineMedium,
            color = Color.White,
            textAlign = TextAlign.Center,
        )
        Spacer(modifier = Modifier.height(16.dp))
        Text(text = appLabel, color = Color(0xFFAEB0B8), textAlign = TextAlign.Center)
        // #473: name the window, so a child in a Study routine and one kept out of school hours stop
        // reading the same sentence. Absent for every other reason, and then nothing is added.
        // #473 review: the words come from resources, so an Arabic phone can show Arabic.
        BlockWindowCopy.line(
            window = window,
            bedtime = stringResource(R.string.block_window_bedtime),
            schoolHours = stringResource(R.string.block_window_school),
            template = stringResource(R.string.block_window_line),
        )?.let { line ->
            Spacer(modifier = Modifier.height(8.dp))
            Text(text = line, color = Color(0xFFAEB0B8), textAlign = TextAlign.Center)
        }
        Spacer(modifier = Modifier.height(40.dp))
        if (sent) {
            Text(text = stringResource(R.string.block_request_sent), color = Color(0xFF9CCC65))
        } else {
            Button(onClick = {
                onRequestAccess()
                sent = true
            }) {
                Text(stringResource(R.string.block_request_access))
            }
        }
        Spacer(modifier = Modifier.height(16.dp))
        TextButton(onClick = onExit) {
            Text(stringResource(R.string.block_exit_home), color = Color.White)
        }
    }
}
