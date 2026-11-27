package com.familyshield.agent.setup

import com.familyshield.agent.BuildConfig
import com.familyshield.agent.R
import android.content.ActivityNotFoundException
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.PackageManager
import android.os.Build
import android.os.Bundle
import android.os.SystemClock
import android.provider.Settings
import android.text.InputFilter
import android.text.InputType
import android.view.View
import android.widget.Button
import android.widget.EditText
import android.widget.LinearLayout
import android.widget.ProgressBar
import android.widget.TextView
import androidx.activity.ComponentActivity
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.platform.ComposeView
import androidx.compose.ui.platform.ViewCompositionStrategy
import androidx.core.content.ContextCompat
import androidx.lifecycle.lifecycleScope
import com.familyshield.agent.ui.pairing.ChecklistCopy
import com.familyshield.agent.ui.pairing.ChecklistRowUi
import com.familyshield.agent.ui.pairing.FamilyAgreementCopy
import com.familyshield.agent.ui.pairing.FamilyRuleItemCopy
import com.familyshield.agent.ui.pairing.FamilyRulesCardCopy
import com.familyshield.agent.ui.pairing.OnboardingChecklistScreen
import com.familyshield.agent.ui.pairing.OnboardingFamilyAgreementScreen
import com.familyshield.agent.ui.pairing.OnboardingLoadingScreen
import com.familyshield.agent.ui.pairing.OnboardingPairingStepScreen
import com.familyshield.agent.ui.pairing.OnboardingPermissionStepScreen
import com.familyshield.agent.ui.pairing.OnboardingWelcomeScreen
import com.familyshield.agent.ui.pairing.PairingStepCopy
import com.familyshield.agent.ui.pairing.PermissionStepCopy
import com.familyshield.agent.ui.pairing.RestrictedSettingsGuideCopy
import com.familyshield.agent.ui.pairing.RoadmapCardCopy
import com.familyshield.agent.ui.pairing.ScannedPairingReviewCopy
import com.familyshield.agent.ui.pairing.TransparencyCardCopy
import com.familyshield.agent.ui.pairing.TransparencyItemCopy
import com.familyshield.agent.ui.pairing.WelcomeCopy
import com.familyshield.agent.ui.theme.ChildUxFlags
import com.familyshield.agent.ui.theme.OsraTheme
import com.familyshield.agent.commands.CommandPollWorker
import com.familyshield.agent.comms.CommsCapture
import com.familyshield.agent.data.AgentSettings
import com.familyshield.agent.data.RuleRepository
import com.familyshield.agent.data.WorkScheduler
import com.familyshield.agent.network.DeviceUnlinker
import com.familyshield.agent.network.ServerUrls
import com.familyshield.agent.network.dto.RuleSetDto
import com.familyshield.agent.security.AdminEnrolmentMessages
import com.familyshield.agent.security.AdminEnrolmentPolicy
import com.familyshield.agent.security.DeviceAdminManager
import com.familyshield.agent.security.Digits
import com.familyshield.agent.security.EnrolmentOutcome
import com.familyshield.agent.security.ParentPin
import com.familyshield.agent.security.ParentPinStore
import com.familyshield.agent.security.ProtectionStatusNote
import com.familyshield.agent.security.ProtectionTier
import com.familyshield.agent.security.TamperGuardActivity
import com.familyshield.agent.services.LocationService
import com.familyshield.agent.services.LocationStartPolicy
import dagger.hilt.android.AndroidEntryPoint
import java.util.concurrent.TimeUnit
import javax.inject.Inject
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
import org.json.JSONObject

/**
 * Launcher pairing flow (§14.2): claims a 6-digit code against a configurable server, stores the
 * device identity in AgentSettings, then starts LocationService and schedules the workers. Already
 * paired devices land on a status screen with a Re-pair option. Plain views (no Compose) to keep
 * the setup screen dependency-free.
 */
@AndroidEntryPoint
class PairingActivity : ComponentActivity() {

    @Inject lateinit var settings: AgentSettings
    @Inject lateinit var rules: RuleRepository
    @Inject lateinit var pinStore: ParentPinStore
    @Inject lateinit var deviceAdmin: DeviceAdminManager
    /** ADR-0034 A2: a new phone is described from its first minute, beside the claim it makes. */
    @Inject lateinit var capabilityReporter: com.familyshield.agent.capabilities.CapabilityReporter

    /** Issue #229: re-check the call/SMS grants on a permission result and on every resume. */
    @Inject lateinit var commsCapture: CommsCapture

    /** C-01 (#1179): time-request posting for Child home (reuses injected [rules] above). */
    @Inject lateinit var api: com.familyshield.agent.network.ApiService

    /** When the admin sheet was launched, so a self-closing refusal can be told from a parent's Cancel. */
    private var adminSheetLaunchedAtMs = 0L

    /**
     * ADR-0010: the OS "activate device admin" screen. The stale-Knox state (#186) is named only when
     * the sheet itself refused as "Admin is already added" (#188) — a returned sheet with no admin
     * and Knox merely present is the ordinary not-granted case. Every other answer keeps the old
     * behaviour.
     */
    private val deviceAdminLauncher = registerForActivityResult(ActivityResultContracts.StartActivityForResult()) { result ->
        deviceAdmin.applyUninstallProtection()
        val elapsedMs = if (adminSheetLaunchedAtMs == 0L) {
            Long.MAX_VALUE
        } else {
            SystemClock.elapsedRealtime() - adminSheetLaunchedAtMs
        }
        adminSheetLaunchedAtMs = 0L
        val alreadyAddedRefusal = AdminEnrolmentPolicy.isAlreadyAddedRefusal(
            resultOk = result.resultCode == RESULT_OK,
            elapsedSinceLaunchMs = elapsedMs,
        )
        val outcome = deviceAdmin.enrolmentOutcome(
            sheetReturned = true,
            alreadyAddedRefusal = alreadyAddedRefusal,
        )
        if (outcome == EnrolmentOutcome.STALE_KNOX_ADMIN) {
            showStaleKnoxAdmin()
            return@registerForActivityResult
        }
        onPermissionOrActionReturned()
    }

    /** Launches the admin sheet through one place, so every return can be timed (issue #188). */
    private fun launchAdminSheet() {
        adminSheetLaunchedAtMs = SystemClock.elapsedRealtime()
        deviceAdminLauncher.launch(deviceAdmin.requestAdminIntent())
    }

    /** Plan 1.4: the OS VPN consent dialog; on OK the sinkhole starts and comes back on every boot. */
    private val vpnConsentLauncher = registerForActivityResult(ActivityResultContracts.StartActivityForResult()) { result ->
        com.familyshield.agent.vpn.VpnState.endOwnConsent()
        if (result.resultCode == RESULT_OK) {
            com.familyshield.agent.vpn.VpnState.setEnabled(this, true)
            com.familyshield.agent.vpn.FilterVpnService.start(this)
        }
        onPermissionOrActionReturned()
    }

    private fun launchVpnConsent(intent: Intent) {
        com.familyshield.agent.vpn.VpnState.beginOwnConsent()
        runCatching { vpnConsentLauncher.launch(intent) }
            .onFailure { com.familyshield.agent.vpn.VpnState.endOwnConsent() }
    }

    /** ADR-0010: parent-PIN gate for Re-pair / Remove protection; RESULT_OK means the PIN was verified. */
    private var pendingGuardedAction: (() -> Unit)? = null
    private val guardLauncher = registerForActivityResult(ActivityResultContracts.StartActivityForResult()) { result ->
        val action = pendingGuardedAction
        pendingGuardedAction = null
        if (result.resultCode == RESULT_OK) action?.invoke()
    }

    // NOTE: READ_CALL_LOG/READ_SMS are dangerous permissions; the request is optional (the agent
    // stays in log-only skip mode without them) so pairing never blocks on it. Issue #229: the
    // registration that failed at start without the permission is retried here, and one harvest
    // runs at once, so a grant takes effect without a reboot.
    private val commsPermissionLauncher = registerForActivityResult(
        ActivityResultContracts.RequestMultiplePermissions(),
    ) { commsCapture.onPermissionsChanged() }

    private val locationPermissionLauncher = registerForActivityResult(
        ActivityResultContracts.RequestMultiplePermissions(),
    ) { permissions ->
        val granted = permissions[android.Manifest.permission.ACCESS_FINE_LOCATION] == true ||
            permissions[android.Manifest.permission.ACCESS_COARSE_LOCATION] == true
        lifecycleScope.launch {
            if (granted) {
                // Short yield so the activity window is fully resumed before starting FGS
                kotlinx.coroutines.delay(200)
                startLocationServiceIfPermitted()
                // Plan 1.6: background location is a second, separate OS prompt on Android 10+.
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q &&
                    ContextCompat.checkSelfPermission(this@PairingActivity, android.Manifest.permission.ACCESS_BACKGROUND_LOCATION) != PackageManager.PERMISSION_GRANTED
                ) {
                    backgroundLocationLauncher.launch(android.Manifest.permission.ACCESS_BACKGROUND_LOCATION)
                    return@launch
                }
            }
            onPermissionOrActionReturned()
        }
    }

    private val backgroundLocationLauncher = registerForActivityResult(ActivityResultContracts.RequestPermission()) {
        onPermissionOrActionReturned()
    }

    /**
     * Roadmap 3.2: the QR scanner returns the raw string only. Parsing, the review card and the
     * explicit confirm stay in this activity, so a scan can never post a pairing request by itself.
     */
    private val scanLauncher = registerForActivityResult(ActivityResultContracts.StartActivityForResult()) { result ->
        val prefillServer = formServer?.text?.toString() ?: composeServer
        val prefillCode = formCode?.text?.toString() ?: composeCode
        val prefillName = formName?.text?.toString() ?: composeName
        val raw = result.data?.getStringExtra(PairQrScanActivity.EXTRA_RAW)
        if (result.resultCode == RESULT_OK && raw != null) {
            when (val state = scanFlow.scan(raw)) {
                is PairingScanFlow.State.Review -> showForm(prefillName = prefillName, scanned = state.payload)
                is PairingScanFlow.State.Rejected -> {
                    // The reason is a technical message, and the Arabic line has no placeholder for it: log it.
                    android.util.Log.w("PairingActivity", "QR rejected: ${state.reason}")
                    showForm(prefillServer, prefillCode, prefillName, scanError = getString(R.string.pair_qr_invalid))
                }
                PairingScanFlow.State.Idle -> showForm(prefillServer, prefillCode, prefillName)
            }
            return@registerForActivityResult
        }
        scanFlow.cancel()
        val message = result.data?.getStringExtra(PairQrScanActivity.EXTRA_ERROR)
            ?: if (result.resultCode == RESULT_OK) {
                getString(R.string.pair_scan_empty)
            } else {
                null
            }
        showForm(prefillServer, prefillCode, prefillName, scanError = message)
    }

    /** Plan 1.6: live grant state, asked of the OS on every render. */
    private val grants: GrantChecks by lazy { GrantChecks(this, deviceAdmin) }

    /** Roadmap 3.2: scan → review → confirm, with no pairing request until [PairingScanFlow.confirm]. */
    // Plan 2.7: a release build pairs only with OSRA's own servers (PairingApproval.isReleasePairingHost).
    private val scanFlow = PairingScanFlow(releaseHostsOnly = !BuildConfig.DEBUG)

    /** The live form fields, so a scanner cancel restores exactly what the parent had typed. */
    private var formServer: EditText? = null
    private var formCode: EditText? = null
    private var formName: EditText? = null
    private var composeServer: String = ""
    private var composeCode: String = ""
    private var composeName: String = ""

    private lateinit var root: LinearLayout

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        root = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            val pad = (16 * resources.displayMetrics.density).toInt()
            setPadding(pad, pad, pad, pad)
            // #440 follow-up: Android 15 is edge to edge at targetSdk 35; keep the title clear of the clock.
            androidx.core.view.ViewCompat.setOnApplyWindowInsetsListener(this) { view, insets ->
                val bars = insets.getInsets(
                    androidx.core.view.WindowInsetsCompat.Type.systemBars() or
                        androidx.core.view.WindowInsetsCompat.Type.displayCutout() or
                        androidx.core.view.WindowInsetsCompat.Type.ime(),
                )
                val p = SystemBarPadding.of(pad, bars.left, bars.top, bars.right, bars.bottom)
                view.setPadding(p.left, p.top, p.right, p.bottom)
                insets
            }
        }
        setContentView(root)
        showLoading()
        // Roadmap 3.2: a rotation must not lose a scanned review; the encoded payload is re-validated
        // through the same state machine, so a tampered bundle cannot smuggle a different code in.
        val restoredScan = savedInstanceState?.getString(KEY_SCANNED_QR)
            ?.let { runCatching { PairQrPayload.decode(it, releaseHostsOnly = !BuildConfig.DEBUG) }.getOrNull() }
        restoredScan?.let { scanFlow.scan(it.encode()) }
        // #433 review (c): the fields are built in code and save no state of their own, so a fold or a
        // rotation used to bring the form back empty — on the QR review, the typed device name was lost
        // and the phone registered under its model. What was typed comes back with the form.
        val typedServer = savedInstanceState?.getString(KEY_TYPED_SERVER).orEmpty()
        val typedCode = savedInstanceState?.getString(KEY_TYPED_CODE).orEmpty()
        val typedName = savedInstanceState?.getString(KEY_TYPED_NAME).orEmpty()
        welcomeCompleted = savedInstanceState?.getBoolean(KEY_WELCOME_COMPLETED, false) ?: false
        activeGuidedStage = savedInstanceState?.getString(KEY_GUIDED_STAGE)
            ?.let { name -> GuidedStage.values().firstOrNull { it.name == name } }
        guidedFirstRun = savedInstanceState?.getBoolean(KEY_GUIDED_FIRST_RUN, true) ?: true
        forceChecklistView = savedInstanceState?.getBoolean(KEY_FORCE_CHECKLIST_VIEW, false) ?: false
        savedInstanceState?.getStringArrayList(KEY_SKIPPED_GRANTS)?.forEach { name ->
            OnboardingPolicy.Grant.values().firstOrNull { it.name == name }?.let { skippedPermissionSteps.add(it) }
        }
        onBackPressedDispatcher.addCallback(this, guidedBackCallback)
        // NOTE: reading the token (not the cache) — a fresh process has empty caches.
        lifecycleScope.launch {
            if (settings.isPaired()) {
                SetupCompletionStore.seedUpgradeLatchIfNeeded(this@PairingActivity, settings.deviceId())
                renderStage(SetupResumePolicy.resolvePairedStage(pinStore.isConfigured(), activeGuidedStage))
            } else {
                SetupCompletionStore.markUpgradeMigrated(this@PairingActivity)
                val hasTypedOrScanned = restoredScan != null ||
                    typedServer.isNotEmpty() || typedCode.isNotEmpty() || typedName.isNotEmpty()
                renderUnpairedStage(
                    prefillServer = typedServer,
                    prefillCode = typedCode,
                    prefillName = typedName,
                    scanned = restoredScan,
                    hasTypedOrScanned = hasTypedOrScanned,
                )
            }
        }
    }

    /**
     * True while the paired **status** screen is the one on display (set by [showStatus], cleared by
     * [showForm]). Both refresh paths check it, so neither can replace a half-typed pairing form.
     */
    @Volatile private var statusScreenShown = false
    private var welcomeCompleted = false
    private var activeGuidedStage: GuidedStage? = null
    private var guidedFirstRun = true
    private var forceChecklistView = false
    private var forceLegacyStatusView = false
    private val skippedPermissionSteps = mutableSetOf<OnboardingPolicy.Grant>()

    /**
     * Issue #1131 review: observes [AccessibilityMonitorService.runningState] only while an
     * ungranted Accessibility step or checklist is visible in the foreground, so returning from
     * Settings before Android finishes binding advances automatically when `onServiceConnected`
     * fires instead of stalling on a stale resume snapshot.
     */
    private val accessibilityBindObserver by lazy {
        AccessibilityBindObserver(
            runningState = com.familyshield.agent.services.AccessibilityMonitorService.runningState,
            isAccessibilityGranted = { grants.isGranted(OnboardingPolicy.Grant.ACCESSIBILITY) },
            onBoundWhileVisible = {
                commsCapture.onPermissionsChanged()
                onPermissionOrActionReturned()
            },
        )
    }

    private val guidedBackCallback: androidx.activity.OnBackPressedCallback =
        object : androidx.activity.OnBackPressedCallback(true) {
            override fun handleOnBackPressed() {
                val rows = OnboardingPolicy.rows(BuildConfig.CAPTURE_NOTIFICATIONS) { grants.isGranted(it) }
                val hasRemainingStep = nextUngrantedPermissionStep(rows) != null
                when (SetupResumePolicy.backAction(activeGuidedStage, guidedFirstRun, hasRemainingStep)) {
                    BackAction.TO_PERMISSION_STEP -> {
                        forceChecklistView = false
                        showChecklist(rows, firstRun = guidedFirstRun)
                    }
                    BackAction.TO_PROTECTION_SETUP -> {
                        if (settings.isPairedSync()) showProtectionSetup() else showChecklist(rows, firstRun = true)
                    }
                    BackAction.TO_STATUS -> finishGuidedSetupAndShowStatus()
                    BackAction.SYSTEM_DEFAULT -> {
                        isEnabled = false
                        onBackPressedDispatcher.onBackPressed()
                        isEnabled = true
                    }
                }
            }
        }

    /**
     * Issue #471: the unlink runs in the agent, not here, so this screen used to keep showing the
     * paired state — "device admin: on", "web filter: connected" — until it was recreated, while the
     * phone was already unlinked.
     *
     * Two paths, because one is not enough:
     * - **while the screen is started** this receiver fires on the agent's [DeviceUnlinker.ACTION_UNLINKED];
     * - **on return from the background** [onResume] finds the phone unpaired and re-renders, because the
     *   receiver is unregistered in `onStop` and would have missed the broadcast entirely (#471 review).
     *
     * Registered for `started`, not `created`: a backgrounded screen does not need a live receiver, and
     * an unregistered one cannot leak.
     */
    private val unlinkedReceiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context?, intent: Intent?) {
            if (intent?.action != DeviceUnlinker.ACTION_UNLINKED) return
            lifecycleScope.launch {
                if (!settings.isPaired() && statusScreenShown) showForm()
            }
        }
    }

    override fun onStart() {
        super.onStart()
        androidx.core.content.ContextCompat.registerReceiver(
            this,
            unlinkedReceiver,
            IntentFilter(DeviceUnlinker.ACTION_UNLINKED),
            androidx.core.content.ContextCompat.RECEIVER_NOT_EXPORTED,
        )
    }

    override fun onPause() {
        accessibilityBindObserver.stop()
        super.onPause()
    }

    override fun onStop() {
        accessibilityBindObserver.stop()
        runCatching { unregisterReceiver(unlinkedReceiver) }
        super.onStop()
    }

    override fun onSaveInstanceState(outState: Bundle) {
        super.onSaveInstanceState(outState)
        outState.putBoolean(KEY_WELCOME_COMPLETED, welcomeCompleted)
        activeGuidedStage?.let { outState.putString(KEY_GUIDED_STAGE, it.name) }
        outState.putBoolean(KEY_GUIDED_FIRST_RUN, guidedFirstRun)
        outState.putBoolean(KEY_FORCE_CHECKLIST_VIEW, forceChecklistView)
        if (skippedPermissionSteps.isNotEmpty()) {
            outState.putStringArrayList(KEY_SKIPPED_GRANTS, ArrayList(skippedPermissionSteps.map { it.name }))
        }
        val review = scanFlow.state as? PairingScanFlow.State.Review
        if (review != null) outState.putString(KEY_SCANNED_QR, review.payload.encode())
        (formServer?.text?.toString() ?: composeServer.takeIf { it.isNotEmpty() })?.let {
            outState.putString(KEY_TYPED_SERVER, it)
        }
        (formCode?.text?.toString() ?: composeCode.takeIf { it.isNotEmpty() })?.let {
            outState.putString(KEY_TYPED_CODE, it)
        }
        (formName?.text?.toString() ?: composeName.takeIf { it.isNotEmpty() })?.let {
            outState.putString(KEY_TYPED_NAME, it)
        }
    }

    override fun onResume() {
        super.onResume()
        // Issue #229: a grant made in Settings (not through this screen) reaches the logger here.
        commsCapture.onPermissionsChanged()
        lifecycleScope.launch {
            if (settings.isPaired()) {
                startLocationServiceIfPermitted()
                val stage = activeGuidedStage
                if (stage == null || stage == GuidedStage.STATUS) {
                    renderStage(SetupResumePolicy.resolvePairedStage(pinStore.isConfigured(), stage))
                } else {
                    onPermissionOrActionReturned()
                }
            } else if (statusScreenShown) {
                // Issue #471 review: this is the return-from-background path. The receiver is
                // unregistered in onStop, so an unlink that happens while the child is in another app
                // used to leave this screen claiming admin and web filter until the activity was
                // recreated. Only the status screen is replaced: a half-typed pairing form stays.
                showForm()
            } else if (
                activeGuidedStage == GuidedStage.PERMISSION_STEP ||
                activeGuidedStage == GuidedStage.CHECKLIST ||
                activeGuidedStage == GuidedStage.STALE_KNOX_ADMIN
            ) {
                // Issue #1174: re-read live grants on every resume during pre-pair onboarding so the
                // progress count is never stale and setup advances to pairing as soon as ready.
                onPermissionOrActionReturned()
            }
        }
    }

    private fun onPermissionOrActionReturned(staleKnox: Boolean = false) {
        lifecycleScope.launch {
            if (!settings.isPaired()) {
                if (staleKnox) {
                    showStaleKnoxAdmin()
                    return@launch
                }
                welcomeCompleted = true
                renderUnpairedStage()
                return@launch
            }
            val rows = OnboardingPolicy.rows(BuildConfig.CAPTURE_NOTIFICATIONS) { grants.isGranted(it) }
            val next = SetupResumePolicy.stageAfterPermissionReturn(
                pinConfigured = pinStore.isConfigured(),
                currentStage = activeGuidedStage,
                isAdminActive = deviceAdmin.isAdminActive(),
                staleKnox = staleKnox,
                canComplete = OnboardingPolicy.canComplete(rows),
                forceChecklist = forceChecklistView,
            )
            renderStage(next)
        }
    }

    private fun renderUnpairedStage(
        prefillServer: String = "",
        prefillCode: String = "",
        prefillName: String = "",
        scanned: PairQrPayload? = null,
        hasTypedOrScanned: Boolean = scanned != null ||
            prefillServer.isNotEmpty() || prefillCode.isNotEmpty() || prefillName.isNotEmpty(),
    ) {
        val rows = OnboardingPolicy.rows(BuildConfig.CAPTURE_NOTIFICATIONS) { grants.isGranted(it) }
        when (
            FirstRunOrderPolicy.resolveUnpairedStage(
                welcomeCompleted = welcomeCompleted,
                requiredGrantsReady = OnboardingPolicy.canComplete(rows),
                forceChecklist = forceChecklistView,
                hasTypedOrScannedPairing = hasTypedOrScanned,
                c05Enabled = ChildUxFlags.c05FirstRunEnabled,
            )
        ) {
            PrePairStage.PRE_PAIR_PERMISSIONS -> {
                forceChecklistView = false
                showChecklist(rows, firstRun = true)
            }
            PrePairStage.PRE_PAIR_CHECKLIST -> {
                forceChecklistView = true
                showChecklist(rows, firstRun = true)
            }
            PrePairStage.PAIRING_FORM -> showForm(prefillServer, prefillCode, prefillName, scanned = scanned)
            else -> showWelcome(prefillServer, prefillCode, prefillName, scanned = scanned)
        }
    }

    private fun renderStage(stage: GuidedStage) {
        when (stage) {
            GuidedStage.SET_PIN -> showSetPin()
            GuidedStage.PROTECTION_SETUP -> showProtectionSetup()
            GuidedStage.STALE_KNOX_ADMIN -> showStaleKnoxAdmin()
            GuidedStage.PERMISSION_STEP -> {
                forceChecklistView = false
                val rows = OnboardingPolicy.rows(BuildConfig.CAPTURE_NOTIFICATIONS) { grants.isGranted(it) }
                if (!OnboardingPolicy.canComplete(rows)) showChecklist(rows, firstRun = guidedFirstRun) else showComplete()
            }
            GuidedStage.CHECKLIST -> {
                forceChecklistView = true
                val rows = OnboardingPolicy.rows(BuildConfig.CAPTURE_NOTIFICATIONS) { grants.isGranted(it) }
                showChecklist(rows, firstRun = guidedFirstRun)
            }
            GuidedStage.COMPLETE -> showComplete()
            GuidedStage.STATUS -> finishGuidedSetupAndShowStatus()
        }
    }

    private fun finishGuidedSetupAndShowStatus() {
        activeGuidedStage = GuidedStage.STATUS
        forceChecklistView = false
        showStatus()
    }

    // ---- states ----

    private fun buildTransparencyCard(): TransparencyCardCopy = TransparencyCardCopy(
        title = getString(R.string.c05_checks_title),
        badge = getString(R.string.c05_checks_badge),
        items = listOf(
            TransparencyItemCopy(
                title = getString(R.string.c05_checks_screen_time_title),
                subtitle = getString(R.string.c05_checks_screen_time_subtitle),
            ),
            TransparencyItemCopy(
                title = getString(R.string.c05_checks_location_title),
                subtitle = getString(R.string.c05_checks_location_subtitle),
            ),
            TransparencyItemCopy(
                title = getString(R.string.c05_checks_messages_title),
                subtitle = getString(R.string.c05_checks_messages_subtitle),
            ),
        ),
    )

    private fun showWelcome(
        prefillServer: String = "",
        prefillCode: String = "",
        prefillName: String = "",
        scanned: PairQrPayload? = null,
    ) {
        statusScreenShown = false
        activeGuidedStage = null
        skippedPermissionSteps.clear()
        val brand = "${getString(R.string.app_name)} · ${getString(R.string.app_name_ar)}"
        val c05 = ChildUxFlags.c05FirstRunEnabled
        replaceWithCompose {
            OnboardingWelcomeScreen(
                copy = WelcomeCopy(
                    brandLabel = brand,
                    title = getString(R.string.setup_welcome_title),
                    body = getString(R.string.setup_welcome_body),
                    start = getString(R.string.setup_welcome_start),
                    stepBadge = if (c05) getString(R.string.c05_step_badge_1) else null,
                    transparencyCard = if (c05) buildTransparencyCard() else null,
                    roadmapCard = if (c05) {
                        RoadmapCardCopy(
                            heading = getString(R.string.c05_roadmap_heading),
                            lines = listOf(
                                getString(R.string.c05_roadmap_step_1),
                                getString(R.string.c05_roadmap_step_2),
                                getString(R.string.c05_roadmap_step_3),
                            ),
                        )
                    } else {
                        null
                    },
                    footerHint = if (c05) getString(R.string.c05_welcome_footer_hint) else null,
                ),
                onStart = {
                    welcomeCompleted = true
                    renderUnpairedStage(
                        prefillServer = prefillServer,
                        prefillCode = prefillCode,
                        prefillName = prefillName,
                        scanned = scanned,
                    )
                },
            )
        }
    }

    private fun showLoading() {
        val brand = "${getString(R.string.app_name)} · ${getString(R.string.app_name_ar)}"
        replaceWithCompose {
            OnboardingLoadingScreen(
                brandLabel = brand,
                title = getString(R.string.pair_title),
            )
        }
    }

    /**
     * The typed form, unchanged for a manual entry. The optional [scanned] payload fills the server
     * and code fields, disables them (the QR is authoritative) and adds the review card whose
     * "Confirm and pair" is the only action that posts. [scanError] explains a refused scan or a
     * denied camera; the form underneath stays usable either way.
     */
    private fun showForm(
        prefillServer: String = "",
        prefillCode: String = "",
        prefillName: String = "",
        scanned: PairQrPayload? = null,
        scanError: String? = null,
    ) {
        statusScreenShown = false
        activeGuidedStage = null
        skippedPermissionSteps.clear()
        if (ChildUxFlags.c05FirstRunEnabled) {
            formServer = null
            formCode = null
            formName = null
            showC05PairingStep(
                prefillServer = prefillServer,
                prefillCode = prefillCode,
                prefillName = prefillName,
                scanned = scanned,
                scanError = scanError,
            )
            return
        }
        composeServer = ""
        composeCode = ""
        composeName = ""
        replaceWith {
            addView(label(getString(R.string.pair_title)))
            addView(label(getString(R.string.pair_intro)))
            // Issue #81: tell whoever holds the phone why it is unpaired; the parent's Allow card says it too.
            if (dataClearedDetected()) {
                addView(label(getString(R.string.wipe_detected_notice)).apply { setTextColor(0xFFB00020.toInt()) })
            }

            if (scanError != null) {
                addView(
                    label(scanError).apply {
                        setTextColor(0xFFB00020.toInt())
                        accessibilityLiveRegion = View.ACCESSIBILITY_LIVE_REGION_POLITE
                    },
                )
            }
            if (scanned != null) {
                addView(label(getString(R.string.pair_scanned_title)).apply { setTextColor(0xFF2E7D32.toInt()) })
                addView(label(getString(R.string.pair_scanned_server, scanned.apiBaseUrl)))
                addView(label(getString(R.string.pair_scanned_code, scanned.maskedCode())))
                addView(
                    label(getString(R.string.pair_scanned_check)),
                )
            }

            // G4: a scanned code wins, then the build's own server, then what the tester typed. A locked
            // field is never empty — `PairingServerFieldPolicy` owns that rule and its rows.
            val serverField = PairingServerFieldPolicy.field(
                scannedUrl = scanned?.apiBaseUrl,
                builtInUrl = com.familyshield.agent.BuildConfig.API_BASE,
                typed = prefillServer,
            )
            val server = editText(serverField.value, InputType.TYPE_TEXT_VARIATION_URI).apply {
                hint = getString(R.string.pair_server_hint)
                isEnabled = serverField.editable
            }
            val code = editText(scanned?.code ?: prefillCode, InputType.TYPE_CLASS_NUMBER).apply {
                filters = arrayOf(InputFilter.LengthFilter(6))
                hint = getString(R.string.pair_code_hint)
                isEnabled = PairingServerFieldPolicy.codeEditable(serverField)
            }
            val name = editText(prefillName, InputType.TYPE_TEXT_FLAG_CAP_WORDS).apply { hint = getString(R.string.pair_name_hint) }
            formServer = server
            formCode = code
            formName = name
            val error = label("").apply {
                setTextColor(0xFFB00020.toInt())
                visibility = View.GONE
            }
            val pairButton = Button(this@PairingActivity).apply {
                text = getString(if (scanned == null) R.string.pair_button else R.string.pair_confirm_button)
            }
            val progress = ProgressBar(this@PairingActivity).apply { visibility = View.GONE }
            val scanButton = Button(this@PairingActivity).apply {
                text = getString(R.string.pair_scan_button)
                contentDescription = getString(R.string.pair_scan_description)
            }
            scanButton.setOnClickListener { startScan() }

            pairButton.setOnClickListener {
                if (scanned == null) {
                    startPair(server.text.toString(), code.text.toString(), name.text.toString(), pairButton, progress, error)
                } else {
                    // Roadmap 3.2: a QR must not pair silently. confirm() is the review state's only
                    // exit to a request, and it returns null if the screen no longer holds a scan.
                    val request = scanFlow.confirm(name.text.toString())
                    if (request == null) {
                        error.text = getString(R.string.pair_error_rescan)
                        error.visibility = View.VISIBLE
                    } else {
                        startPair(request.serverUrl, request.code, request.deviceName, pairButton, progress, error)
                    }
                }
            }

            addView(labeled(getString(R.string.pair_server_label), server))
            addView(labeled(getString(R.string.pair_code_label), code))
            addView(labeled(getString(R.string.pair_name_label), name))
            addView(pairButton)
            addView(progress)
            addView(scanButton)
            if (scanned != null) {
                addView(
                    Button(this@PairingActivity).apply {
                        text = getString(R.string.pair_cancel)
                        setOnClickListener {
                            scanFlow.cancel()
                            showForm()
                        }
                    },
                )
            }
            addView(error)
        }
    }

    /**
     * C-05 (#1208 B1): Step 2 of 3 pairing hand-off rendered inside the Compose C-05 step scaffold.
     * Server URL and device name are preset and hidden; the existing QR scanner (`PairQrScanActivity`)
     * stays wired with Roadmap 3.2's explicit review-and-confirm gate.
     */
    private fun showC05PairingStep(
        prefillServer: String = "",
        prefillCode: String = "",
        prefillName: String = "",
        scanned: PairQrPayload? = null,
        scanError: String? = null,
    ) {
        val brand = "${getString(R.string.app_name)} · ${getString(R.string.app_name_ar)}"
        val serverField = PairingServerFieldPolicy.field(
            scannedUrl = scanned?.apiBaseUrl,
            builtInUrl = com.familyshield.agent.BuildConfig.API_BASE,
            typed = prefillServer,
        )
        val presetServer = serverField.value
        val presetName = prefillName.trim()
        composeServer = presetServer
        composeCode = scanned?.code ?: prefillCode
        composeName = presetName

        val reviewCopy = scanned?.let {
            ScannedPairingReviewCopy(
                title = getString(R.string.pair_scanned_title),
                codeLine = getString(R.string.pair_scanned_code, it.maskedCode()),
                checkLine = getString(R.string.pair_scanned_check),
                confirmButton = getString(R.string.pair_confirm_button),
                cancelButton = getString(R.string.pair_cancel),
            )
        }
        val copy = PairingStepCopy(
            brandLabel = brand,
            stepBadge = getString(R.string.c05_step_badge_2),
            title = getString(R.string.c05_pair_title),
            codeLabel = getString(R.string.c05_pair_code_label),
            codeHint = getString(R.string.c05_pair_code_hint),
            connectButton = getString(R.string.c05_pair_connect),
            scanQrButton = getString(R.string.c05_pair_scan_qr),
            wipeNotice = if (dataClearedDetected()) getString(R.string.wipe_detected_notice) else null,
            scannedReview = reviewCopy,
        )

        replaceWithCompose {
            var code by remember(scanned, prefillCode) { mutableStateOf(scanned?.code ?: prefillCode) }
            var isConnecting by remember { mutableStateOf(false) }
            var waitingMessage by remember { mutableStateOf<String?>(null) }
            var errorMessage by remember(scanError) { mutableStateOf(scanError) }

            OnboardingPairingStepScreen(
                copy = copy,
                code = code,
                onCodeChange = { updated ->
                    code = updated
                    composeCode = updated
                    if (errorMessage != null) errorMessage = null
                },
                onConnect = {
                    val targetServer: String
                    val targetCode: String
                    val targetName: String
                    if (scanned != null) {
                        val request = scanFlow.confirm(presetName)
                        if (request == null) {
                            errorMessage = getString(R.string.pair_error_rescan)
                            return@OnboardingPairingStepScreen
                        }
                        targetServer = request.serverUrl
                        targetCode = request.code
                        targetName = request.deviceName
                    } else {
                        targetServer = presetServer
                        targetCode = code
                        targetName = presetName
                    }
                    executePair(
                        enteredServer = targetServer,
                        enteredCode = targetCode,
                        deviceName = targetName,
                        onBusyChanged = { busy -> isConnecting = busy },
                        onWaiting = { msg -> waitingMessage = msg },
                        onError = { msg ->
                            waitingMessage = null
                            errorMessage = msg
                        },
                    )
                },
                onScanQr = { startScan() },
                onCancelScan = if (scanned != null) {
                    {
                        scanFlow.cancel()
                        showForm()
                    }
                } else {
                    null
                },
                isConnecting = isConnecting,
                waitingMessage = waitingMessage,
                errorMessage = errorMessage,
            )
        }
    }

    private fun startScan() {
        scanFlow.cancel()
        runCatching { scanLauncher.launch(Intent(this, PairQrScanActivity::class.java)) }
            .onFailure {
                showForm(
                    formServer?.text?.toString() ?: composeServer,
                    formCode?.text?.toString() ?: composeCode,
                    formName?.text?.toString() ?: composeName,
                    scanError = getString(R.string.pair_no_camera),
                )
            }
    }

    /** The one pairing path: typed code and scanned code both end here, with the same validation. */
    private fun startPair(
        enteredServer: String,
        enteredCode: String,
        deviceName: String,
        pairButton: Button,
        progress: ProgressBar,
        error: TextView,
    ) {
        executePair(
            enteredServer = enteredServer,
            enteredCode = enteredCode,
            deviceName = deviceName,
            onBusyChanged = { busy ->
                pairButton.isEnabled = !busy
                progress.visibility = if (busy) View.VISIBLE else View.GONE
            },
            onWaiting = { msg ->
                error.setTextColor(0xFF444444.toInt())
                error.text = msg
                error.visibility = View.VISIBLE
            },
            onError = { msg ->
                error.setTextColor(0xFFB00020.toInt())
                if (msg == null) {
                    error.visibility = View.GONE
                } else {
                    error.text = msg
                    error.visibility = View.VISIBLE
                }
            },
        )
    }

    private fun executePair(
        enteredServer: String,
        enteredCode: String,
        deviceName: String,
        onBusyChanged: (Boolean) -> Unit,
        onWaiting: (String) -> Unit,
        onError: (String?) -> Unit,
    ) {
        val serverUrl = enteredServer.trim()
        if (serverUrl.isBlank()) {
            onError(getString(R.string.pair_error_server))
            return
        }
        val code = Digits.normalize(enteredCode.trim())
        if (!code.matches(Regex("\\d{6}"))) {
            onError(getString(R.string.pair_error_code))
            return
        }
        onBusyChanged(true)
        onError(null)
        val name = deviceName.trim()
        lifecycleScope.launch {
            val result = runCatching {
                claim(serverUrl, code, name) {
                    // Plan 2.7: the code is claimed; nothing is paired until the parent taps Allow.
                    onWaiting(getString(R.string.pair_waiting))
                }
            }
            onBusyChanged(false)
            onError(null)
            result.onSuccess { pairing ->
                if (settings.savePairing(pairing.baseUrl, pairing.token, pairing.deviceId, pairing.childId, pairing.hmacSecret)) {
                    val rows = OnboardingPolicy.rows(BuildConfig.CAPTURE_NOTIFICATIONS) { grants.isGranted(it) }
                    if (OnboardingPolicy.canComplete(rows)) {
                        SetupCompletionStore.markCompleted(this@PairingActivity, pairing.deviceId)
                    }
                    startAgent()
                    // ADR-0010: the parent is holding the phone right now — this is the moment to set the PIN
                    // that gates every protection-removal action from here on.
                    if (pinStore.isConfigured()) showProtectionSetup() else showSetPin()
                } else {
                    // osra-security#8 F2 follow-up: the secure store could not persist the pairing, so nothing
                    // was started and nothing is cached as paired. The form already names the state above.
                    onError(getString(R.string.pairing_secure_store_failed))
                }
            }.onFailure { e ->
                onError(userMessage(e))
            }
        }
    }

    /** ADR-0010 step 1: the parent chooses the PIN (4–8 digits, not a weak one). */
    private fun showSetPin() {
        statusScreenShown = false
        activeGuidedStage = GuidedStage.SET_PIN
        guidedFirstRun = true
        replaceWith {
            addView(label(getString(R.string.title_brand_suffix, getString(R.string.pair_pin_title))))
            addView(
                label(getString(R.string.pair_pin_body)),
            )
            val pin = editText("", InputType.TYPE_CLASS_NUMBER or InputType.TYPE_NUMBER_VARIATION_PASSWORD).apply {
                hint = getString(R.string.pair_pin_hint)
                filters = arrayOf(InputFilter.LengthFilter(ParentPin.MAX_LENGTH))
            }
            val again = editText("", InputType.TYPE_CLASS_NUMBER or InputType.TYPE_NUMBER_VARIATION_PASSWORD).apply {
                hint = getString(R.string.pair_pin_repeat)
                filters = arrayOf(InputFilter.LengthFilter(ParentPin.MAX_LENGTH))
            }
            val error = TextView(this@PairingActivity).apply { setTextColor(0xFFB00020.toInt()); visibility = View.GONE }
            addView(labeled(getString(R.string.pair_pin_label), pin))
            addView(labeled(getString(R.string.pair_pin_repeat), again))
            addView(
                Button(this@PairingActivity).apply {
                    text = getString(R.string.pair_pin_save)
                    setOnClickListener {
                        val p = Digits.normalize(pin.text.toString())
                        val reason = ParentPin.validationError(p) ?: if (p != Digits.normalize(again.text.toString())) getString(R.string.pair_pin_mismatch) else null
                        if (reason != null) {
                            error.text = reason
                            error.visibility = View.VISIBLE
                            return@setOnClickListener
                        }
                        pinStore.set(p)
                        showProtectionSetup()
                    }
                },
            )
            addView(error)
        }
    }

    /** ADR-0010 step 2: activate Device Admin (uninstall needs the PIN from then on; remote lock works). */
    private fun showProtectionSetup() {
        statusScreenShown = false
        activeGuidedStage = GuidedStage.PROTECTION_SETUP
        guidedFirstRun = true
        if (deviceAdmin.isAdminActive()) {
            deviceAdmin.applyUninstallProtection()
            showComplete()
            return
        }
        replaceWith {
            addView(label(getString(R.string.setup_protect_title)))
            addView(label(getString(R.string.setup_protect_body)))
            addView(
                Button(this@PairingActivity).apply {
                    text = getString(R.string.setup_activate_admin)
                    setOnClickListener { launchAdminSheet() }
                },
            )
            addView(
                Button(this@PairingActivity).apply {
                    text = getString(R.string.setup_skip)
                    setOnClickListener { showComplete() }
                },
            )
        }
    }

    /**
     * The specific dead end from #181/#186: Samsung's Knox registry still lists us although AOSP says
     * no admin, so the sheet's Activate is refused and closes. The app cannot clear another layer's
     * registry entry; it can only name the state and open the screen that goes through Knox.
     */
    private fun showStaleKnoxAdmin() {
        statusScreenShown = false
        activeGuidedStage = GuidedStage.STALE_KNOX_ADMIN
        val message = AdminEnrolmentMessages.resForOutcome(EnrolmentOutcome.STALE_KNOX_ADMIN) ?: return
        replaceWith {
            addView(
                label(getString(R.string.title_brand_suffix, getString(message.titleRes))).apply {
                    setTextColor(0xFFB00020.toInt())
                },
            )
            addView(label(getString(message.bodyRes)))
            addView(label(message.recovery))
            addView(
                Button(this@PairingActivity).apply {
                    text = getString(message.actionRes)
                    setOnClickListener { openDeviceAdminSettings() }
                },
            )
            addView(
                Button(this@PairingActivity).apply {
                    text = getString(R.string.setup_try_activate_again)
                    setOnClickListener { launchAdminSheet() }
                },
            )
            addView(
                Button(this@PairingActivity).apply {
                    text = getString(R.string.setup_continue_without)
                    setOnClickListener {
                        if (settings.isPairedSync()) showComplete() else showForm()
                    }
                },
            )
        }
    }

    private fun openDeviceAdminSettings() {
        // The direct action is not in the public SDK constant list (it is a Settings intent string);
        // fall back to Security, from which Device admin apps is one tap away.
        try {
            startActivity(Intent("android.settings.DEVICE_ADMIN_SETTINGS"))
        } catch (e: ActivityNotFoundException) {
            runCatching { startActivity(Intent(Settings.ACTION_SECURITY_SETTINGS)) }
                .onFailure { android.util.Log.w("PairingActivity", "no device-admin settings screen", it) }
        }
    }

    /**
     * Issue #81 and osra-security#8 F2 follow-up: an unpaired phone whose OSRA data was cleared while admin stayed
     * active, or whose encrypted store failed closed, is recognised here and flags the next claim and the form notice.
     */
    private fun dataClearedDetected(): Boolean =
        // osra-security#8 F2 follow-up: a fail-closed store is a wipe signature too, whatever the admin tier.
        settings.secureStoreUnreadable() ||
            WipeDetector.dataCleared(deviceAdmin.isAdminActive(), paired = false, pinConfigured = pinStore.isConfigured())

    /** Runs [action] only after the parent PIN is verified on the guard screen; no PIN yet → runs at once. */
    private fun requirePin(reason: String, action: () -> Unit) {
        if (!pinStore.isConfigured()) { action(); return }
        pendingGuardedAction = action
        guardLauncher.launch(Intent(this, TamperGuardActivity::class.java).putExtra(TamperGuardActivity.EXTRA_REASON, reason))
    }

    private fun showComplete() {
        val rows = OnboardingPolicy.rows(BuildConfig.CAPTURE_NOTIFICATIONS) { grants.isGranted(it) }
        if (!OnboardingPolicy.canComplete(rows)) { showChecklist(rows, firstRun = guidedFirstRun); return }
        if (settings.isPairedSync()) {
            SetupCompletionStore.markCompleted(this, settings.deviceIdSync())
        }
        statusScreenShown = false
        activeGuidedStage = GuidedStage.COMPLETE
        if (ChildUxFlags.c05FirstRunEnabled) {
            val cached = rules.cachedRules()
            renderC05Agreement(rows, cached)
            if (cached == null) {
                lifecycleScope.launch {
                    val disk = rules.currentRules()
                    if (disk != null && activeGuidedStage == GuidedStage.COMPLETE) {
                        renderC05Agreement(rows, disk)
                    }
                }
            }
            return
        }
        replaceWith {
            addView(label(getString(R.string.setup_complete_title)))
            addView(label(progressLine(rows)).apply { setTextColor(0xFF2E7D32.toInt()) })
            addView(label(getString(R.string.setup_complete_body)))
            for (row in rows.filter { !it.granted }) addGrantRow(this, row) // the recommended ones still open
            // ADR-0021 B3: the Play artefact has no call-log/SMS permissions, so the invite and the button
            // exist only where the capability does; the notice below says what this build cannot capture.
            if (BuildConfig.CAPTURE_CALL_SMS) {
                addView(
                    label(getString(R.string.setup_call_sms_invite)),
                )
                addView(
                    Button(this@PairingActivity).apply {
                        text = getString(R.string.setup_grant_call_sms)
                        setOnClickListener { commsPermissionLauncher.launch(COMMS_PERMISSIONS) }
                    },
                )
            }
            OnboardingPolicy.captureNoticeRes(BuildConfig.CAPTURE_NOTIFICATIONS, BuildConfig.CAPTURE_CALL_SMS)?.let {
                addView(label(getString(it)).apply { setTextColor(0xFF616161.toInt()) })
            }
            addView(
                Button(this@PairingActivity).apply {
                    text = getString(R.string.setup_open_status)
                    setOnClickListener { finishGuidedSetupAndShowStatus() }
                },
            )
        }
    }

    /**
     * Plan 1.6: the guided checklist. Every grant is a row with its reason, the OEM hint when there is
     * one, and a button that opens exactly the screen that grants it; the rows are re-asked of the OS
     * on every resume, so coming back from Settings without granting leaves the row red. Pairing is
     * not "complete" (and the status screen says so) until the required rows are green.
     */
    private fun showChecklist(rows: List<OnboardingPolicy.Row>, firstRun: Boolean) {
        statusScreenShown = false
        guidedFirstRun = firstRun
        val nextStep = if (forceChecklistView) null else nextUngrantedPermissionStep(rows)
        if (nextStep != null) {
            showPermissionStep(rows, nextStep, firstRun)
            return
        }
        activeGuidedStage = GuidedStage.CHECKLIST
        forceChecklistView = false
        val brand = "${getString(R.string.app_name)} · ${getString(R.string.app_name_ar)}"
        val copy = ChecklistCopy(
            brandLabel = brand,
            title = getString(
                if (firstRun) R.string.setup_checklist_first_title else R.string.setup_checklist_title,
            ),
            progressLine = progressLine(rows),
            canComplete = OnboardingPolicy.canComplete(rows),
            intro = if (firstRun) getString(R.string.setup_checklist_intro) else null,
            rows = rows.map { row ->
                val g = row.grant
                val c05 = ChildUxFlags.c05FirstRunEnabled
                ChecklistRowUi(
                    title = getString(if (c05) g.c05TitleRes else g.titleRes),
                    whyOneSentence = getString(if (c05) g.c05WhyRes else g.whyRes),
                    granted = row.granted,
                    required = g.required,
                    optionalBadge = if (g.required) null else getString(R.string.setup_recommended),
                    oemHint = OnboardingPolicy.oemHint(g, Build.MANUFACTURER),
                    grantLabel = if (c05) {
                        getString(g.c05ButtonRes)
                    } else {
                        getString(R.string.setup_grant_button, getString(g.titleRes))
                    },
                    onGrant = { triggerGrant(g) },
                )
            },
            footerLabel = when {
                !firstRun -> getString(R.string.setup_back)
                OnboardingPolicy.canComplete(rows) -> getString(
                    if (settings.isPairedSync()) R.string.setup_done else R.string.c05_continue_to_pairing,
                )
                else -> null
            },
            onFooterClick = when {
                !firstRun -> { { finishGuidedSetupAndShowStatus() } }
                OnboardingPolicy.canComplete(rows) -> {
                    { if (settings.isPairedSync()) showComplete() else showForm() }
                }
                else -> null
            },
        )
        replaceWithCompose {
            OnboardingChecklistScreen(copy = copy)
        }
        if (rows.any { it.grant == OnboardingPolicy.Grant.ACCESSIBILITY && !it.granted }) {
            accessibilityBindObserver.arm(lifecycleScope, lifecycle)
        }
    }

    private fun nextUngrantedPermissionStep(rows: List<OnboardingPolicy.Row>): OnboardingPolicy.Row? =
        rows.firstOrNull { !it.granted && it.grant.required && it.grant !in skippedPermissionSteps }
            ?: rows.firstOrNull { !it.granted && it.grant !in skippedPermissionSteps }

    private fun showPermissionStep(
        rows: List<OnboardingPolicy.Row>,
        row: OnboardingPolicy.Row,
        firstRun: Boolean,
    ) {
        statusScreenShown = false
        guidedFirstRun = firstRun
        activeGuidedStage = GuidedStage.PERMISSION_STEP
        val g = row.grant
        val brand = "${getString(R.string.app_name)} · ${getString(R.string.app_name_ar)}"
        val restrictedGuide = if (
            g == OnboardingPolicy.Grant.ACCESSIBILITY &&
            !row.granted &&
            RestrictedSettingsPolicy.requiresGuide(
                sdkInt = Build.VERSION.SDK_INT,
                installerPackageName = RestrictedSettingsPolicy.installerPackageName(this),
                isPlayBuild = !BuildConfig.CAPTURE_NOTIFICATIONS,
            )
        ) {
            val serviceLabel = RestrictedSettingsPolicy.isolateServiceLabel(
                getString(R.string.accessibility_service_label),
            )
            RestrictedSettingsGuideCopy(
                steps = listOf(
                    getString(R.string.restricted_settings_step_1, serviceLabel),
                    getString(R.string.restricted_settings_step_2),
                    getString(R.string.restricted_settings_step_3, serviceLabel),
                ),
                openAppInfoButton = getString(R.string.restricted_settings_open_app_info),
                waitingLine = getString(R.string.restricted_settings_waiting, serviceLabel),
            )
        } else {
            null
        }
        val c05 = ChildUxFlags.c05FirstRunEnabled
        val copy = PermissionStepCopy(
            brandLabel = brand,
            progressLine = progressLine(rows),
            title = getString(if (c05) g.c05TitleRes else g.titleRes),
            whyOneSentence = getString(if (c05) g.c05WhyRes else g.whyRes),
            grantButton = if (c05) {
                getString(g.c05ButtonRes)
            } else {
                getString(R.string.setup_grant_button, getString(g.titleRes))
            },
            optionalBadge = if (g.required) null else getString(R.string.setup_recommended),
            oemHint = OnboardingPolicy.oemHint(g, Build.MANUFACTURER),
            restrictedSettingsGuide = restrictedGuide,
            skipLabel = if (!g.required) getString(R.string.setup_skip) else null,
            checklistLabel = getString(R.string.setup_checklist_button),
        )
        replaceWithCompose {
            OnboardingPermissionStepScreen(
                copy = copy,
                onGrant = { triggerGrant(g) },
                onOpenAppInfo = if (restrictedGuide != null) {
                    { runCatching { startActivity(grants.appInfoIntent()) } }
                } else {
                    null
                },
                onSkip = if (!g.required) {
                    {
                        skippedPermissionSteps.add(g)
                        val remaining = nextUngrantedPermissionStep(rows)
                        if (remaining != null) showPermissionStep(rows, remaining, firstRun)
                        else if (!settings.isPairedSync()) {
                            if (OnboardingPolicy.canComplete(rows)) showForm() else showChecklist(rows, firstRun)
                        }
                        else if (firstRun) showComplete()
                        else finishGuidedSetupAndShowStatus()
                    }
                } else null,
                onOpenChecklist = {
                    forceChecklistView = true
                    showChecklist(rows, firstRun)
                },
            )
        }
        if (g == OnboardingPolicy.Grant.ACCESSIBILITY && !row.granted) {
            accessibilityBindObserver.arm(lifecycleScope, lifecycle)
        }
    }

    private fun triggerGrant(g: OnboardingPolicy.Grant) {
        when (g) {
            OnboardingPolicy.Grant.DEVICE_ADMIN -> launchAdminSheet()
            OnboardingPolicy.Grant.WEB_FILTER -> {
                val prepare = android.net.VpnService.prepare(this)
                if (prepare != null) launchVpnConsent(prepare) else {
                    com.familyshield.agent.vpn.VpnState.setEnabled(this, true)
                    com.familyshield.agent.vpn.FilterVpnService.start(this)
                    onPermissionOrActionReturned()
                }
            }
            OnboardingPolicy.Grant.LOCATION -> {
                val hasAny = ContextCompat.checkSelfPermission(this, android.Manifest.permission.ACCESS_FINE_LOCATION) == PackageManager.PERMISSION_GRANTED
                if (hasAny && Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) backgroundLocationLauncher.launch(android.Manifest.permission.ACCESS_BACKGROUND_LOCATION)
                else requestLocationPermission()
            }
            else -> grants.fixIntent(g)?.let { runCatching { startActivity(it) } }
        }
    }

    private fun addGrantRow(container: LinearLayout, row: OnboardingPolicy.Row) {
        val g = row.grant
        val mark = if (row.granted) "✓" else if (g.required) "⚠️" else "○"
        val suffix = if (g.required) "" else " " + getString(R.string.setup_recommended)
        container.addView(
            label("$mark ${getString(g.titleRes)}$suffix").apply {
                setTextColor(if (row.granted) 0xFF2E7D32.toInt() else if (g.required) 0xFFB00020.toInt() else 0xFF616161.toInt())
            },
        )
        if (row.granted) return
        container.addView(label(getString(g.whyRes)))
        OnboardingPolicy.oemHint(g, Build.MANUFACTURER)?.let { container.addView(label(it)) }
        val button = Button(this).apply {
            text = getString(R.string.setup_grant_button, getString(g.titleRes))
            setOnClickListener { triggerGrant(g) }
        }
        container.addView(button)
    }

    /**
     * Plan 1.4: the web filter (DNS sinkhole) needs the one-time OS VPN consent. The row shows the
     * state (consent missing / connected / disconnected) and offers the consent dialog or a reconnect.
     */
    private fun addWebFilterRow(container: LinearLayout) {
        val prepare = android.net.VpnService.prepare(this)
        if (prepare != null) {
            container.addView(
                label(getString(R.string.setup_web_filter_missing)).apply {
                    setTextColor(0xFFB00020.toInt())
                },
            )
            container.addView(
                Button(this).apply {
                    text = getString(R.string.setup_web_filter_setup)
                    setOnClickListener { launchVpnConsent(prepare) }
                },
            )
            return
        }
        if (!com.familyshield.agent.vpn.VpnState.isEnabled(this)) {
            com.familyshield.agent.vpn.VpnState.setEnabled(this, true)
        }
        if (com.familyshield.agent.vpn.VpnState.isEstablished(this)) {
            container.addView(label(getString(R.string.setup_web_filter_connected)))
        } else {
            container.addView(
                label(getString(R.string.setup_web_filter_disconnected)).apply { setTextColor(0xFFB00020.toInt()) },
            )
            container.addView(
                Button(this).apply {
                    text = getString(R.string.setup_web_filter_reconnect)
                    setOnClickListener {
                        com.familyshield.agent.vpn.FilterVpnService.start(this@PairingActivity)
                        lifecycleScope.launch { kotlinx.coroutines.delay(800); if (settings.isPaired()) showStatus() }
                    }
                },
            )
        }
    }

    private fun showStatus() {
        // ADR-0010 §2 (#440 Flip4 follow-up): no status screen, and so no ungated action, before a PIN exists.
        if (SetupResumePolicy.pairedScreen(pinStore.isConfigured()) == PairedScreen.SET_PIN) {
            statusScreenShown = false
            showSetPin()
            return
        }
        activeGuidedStage = GuidedStage.STATUS
        statusScreenShown = true
        val forceLegacy = forceLegacyStatusView
        forceLegacyStatusView = false
        lifecycleScope.launch {
            val childId = settings.childId() ?: "-"
            val deviceId = settings.deviceId() ?: "-"
            val server = settings.baseUrl() ?: "-"
            val hasFine = ContextCompat.checkSelfPermission(this@PairingActivity, android.Manifest.permission.ACCESS_FINE_LOCATION) == PackageManager.PERMISSION_GRANTED
            val hasCoarse = ContextCompat.checkSelfPermission(this@PairingActivity, android.Manifest.permission.ACCESS_COARSE_LOCATION) == PackageManager.PERMISSION_GRANTED
            val hasLocation = hasFine || hasCoarse

            if (hasLocation) {
                startLocationServiceIfPermitted()
            }

            val isRunning = LocationService.isServiceRunning
            // Issue #221 D3: a while-in-use grant can start the foreground service but cannot be
            // started from the background, so the tick belongs only to the "allow all the time"
            // state. LocationStartPolicy already owns that judgement; the line comes from it.
            val hasBackground = ContextCompat.checkSelfPermission(
                this@PairingActivity,
                android.Manifest.permission.ACCESS_BACKGROUND_LOCATION,
            ) == PackageManager.PERMISSION_GRANTED
            // Issue #221 (D1 follow-up): a grant change reaches the server now, not at the next
            // 15-minute telemetry tick, so a Locate sent seconds after "Allow all the time" is
            // delivered instead of refused. No-op when nothing changed.
            try {
                dagger.hilt.android.EntryPointAccessors.fromApplication(
                    applicationContext,
                    com.familyshield.agent.di.WorkerEntryPoint::class.java,
                ).usageReporter().reportLocationGrantIfChanged()
                // ADR-0034 A2: the same seam for the capability report — a grant a parent has just fixed
                // reaches the server now, and a resume with nothing changed sends nothing.
                dagger.hilt.android.EntryPointAccessors.fromApplication(
                    applicationContext,
                    com.familyshield.agent.di.WorkerEntryPoint::class.java,
                ).usageReporter().reportCapabilitiesIfChanged()
            } catch (e: kotlinx.coroutines.CancellationException) {
                throw e
            } catch (e: Exception) {
                android.util.Log.w("PairingActivity", "location grant report failed", e)
            }

            if (!forceLegacy && com.familyshield.agent.ui.theme.ChildUxFlags.c01ChildHomeEnabled) {
                val initialCopy = buildChildHomeCopy()
                childHomeCopyState.value = initialCopy
                replaceWithCompose {
                    com.familyshield.agent.ui.home.ChildHomeScreen(
                        copy = childHomeCopyState.value ?: initialCopy,
                        onCallParent = {
                            runCatching {
                                startActivity(Intent(Intent.ACTION_DIAL).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
                            }
                        },
                        onRequestMoreTime = { minutes -> sendChildHomeTimeRequest(minutes) },
                        onSendSos = {
                            runCatching {
                                startActivity(
                                    Intent(this@PairingActivity, com.familyshield.agent.sos.SosActivity::class.java)
                                        .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK),
                                )
                            }
                        },
                        onOpenDeviceSetup = {
                            forceLegacyStatusView = true
                            showStatus()
                        },
                        requestSendState = childHomeSendState.value,
                    )
                }
                return@launch
            }

            val tier = deviceAdmin.tier()
            replaceWith {
                addView(label(getString(R.string.status_paired_title)))
                addView(label(getString(R.string.status_identity, childId, deviceId, server)))
                addView(
                    label(
                        "\n" + getString(
                            when (tier) {
                                ProtectionTier.OWNER -> R.string.status_protection_owner
                                ProtectionTier.ADMIN -> R.string.status_protection_admin
                                ProtectionTier.NONE -> R.string.status_protection_alert_only
                            },
                        ),
                    ).apply { setTextColor(if (tier == ProtectionTier.NONE) 0xFFB00020.toInt() else 0xFF2E7D32.toInt()) },
                )
                if (tier == ProtectionTier.NONE) {
                    addView(
                        Button(this@PairingActivity).apply {
                            text = getString(R.string.setup_activate_admin)
                            setOnClickListener { launchAdminSheet() }
                        },
                    )
                    // Knox merely existing is not evidence of a stale row (#188): a parent-PIN removal
                    // leaves this screen exactly like this and re-activation works. The stale-record
                    // text is only shown after the sheet itself refused (deviceAdminLauncher above).
                    if (AdminEnrolmentPolicy.statusNote(tier, deviceAdmin.wasAdminRemovedByParent) ==
                        ProtectionStatusNote.REMOVED_BY_PARENT
                    ) {
                        addView(
                            label("\n" + getString(R.string.admin_parent_removal_note)).apply {
                                setTextColor(0xFF616161.toInt())
                            },
                        )
                    }
                }
                val locationStatus = LocationStatusPolicy.classify(
                    hasFineLocation = hasFine,
                    hasCoarseLocation = hasCoarse,
                    hasBackgroundLocation = hasBackground,
                    apiLevel = Build.VERSION.SDK_INT,
                    serviceRunning = isRunning,
                )
                addView(
                    label("\n" + getString(LocationStatusPolicy.lineRes(locationStatus))).apply {
                        setTextColor(
                            when (locationStatus) {
                                LocationStatus.ACTIVE -> 0xFF2E7D32.toInt()
                                LocationStatus.MISSING_PERMISSION -> 0xFFB00020.toInt()
                                else -> 0xFFE65100.toInt()
                            },
                        )
                    },
                )
                LocationStatusPolicy.actionRes(locationStatus)?.let { action ->
                    addView(
                        Button(this@PairingActivity).apply {
                            text = getString(action)
                            setOnClickListener { onLocationStatusAction(locationStatus) }
                        },
                    )
                }

                addView(
                    Button(this@PairingActivity).apply {
                        text = getString(R.string.status_open_accessibility)
                        setOnClickListener { startActivity(Intent(Settings.ACTION_ACCESSIBILITY_SETTINGS)) }
                    },
                )
                val rows = OnboardingPolicy.rows(BuildConfig.CAPTURE_NOTIFICATIONS) { grants.isGranted(it) }
                val missing = OnboardingPolicy.missingRequired(rows)
                addView(
                    label(
                        "\n" + progressLine(rows) +
                            if (missing.isEmpty()) {
                                ""
                            } else {
                                "\n" + getString(
                                    R.string.status_missing,
                                    missing.joinToString(getString(R.string.list_separator)) { getString(it.titleRes) },
                                )
                            },
                    ).apply {
                        setTextColor(if (missing.isEmpty()) 0xFF2E7D32.toInt() else 0xFFB00020.toInt())
                    },
                )
                OnboardingPolicy.captureNoticeRes(BuildConfig.CAPTURE_NOTIFICATIONS, BuildConfig.CAPTURE_CALL_SMS)?.let {
                    addView(label(getString(it)).apply { setTextColor(0xFF616161.toInt()) })
                }
                addView(
                    Button(this@PairingActivity).apply {
                        text = if (missing.isEmpty()) {
                            getString(R.string.setup_checklist_button)
                        } else {
                            resources.getQuantityString(R.plurals.setup_finish_protection, missing.size, missing.size)
                        }
                        setOnClickListener { showChecklist(OnboardingPolicy.rows(BuildConfig.CAPTURE_NOTIFICATIONS) { grants.isGranted(it) }, firstRun = false) }
                    },
                )
                addWebFilterRow(this)
                addView(
                    Button(this@PairingActivity).apply {
                        text = getString(R.string.status_repair)
                        setOnClickListener {
                            requirePin(TamperGuardActivity.REASON_REPAIR) {
                                lifecycleScope.launch {
                                    settings.clearPairing()
                                    activeGuidedStage = null
                                    skippedPermissionSteps.clear()
                                    showForm()
                                }
                            }
                        }
                    },
                )
                addView(
                    Button(this@PairingActivity).apply {
                        text = getString(R.string.status_remove_protection)
                        setOnClickListener {
                            requirePin(TamperGuardActivity.REASON_REMOVE) {
                                deviceAdmin.removeAdmin()
                                lifecycleScope.launch {
                                    kotlinx.coroutines.delay(300)
                                    showStatus()
                                }
                            }
                        }
                    },
                )
            }
        }
    }

    // ---- pairing request ----

    /**
     * Claims the code, then waits for the parent's decision (plan 2.7): the claim answers 202 with a
     * claim id and a poll secret, and the device token arrives on the poll after the parent taps Allow.
     * [onWaiting] runs on the main thread once the claim is accepted. Throws [InvalidCodeException] for
     * an unknown code and [PairingRefusedException] with a message for every other ending.
     */
    private suspend fun claim(serverUrl: String, code: String, deviceName: String, onWaiting: () -> Unit): PairingResult =
        withContext(Dispatchers.IO) {
            // NOTE: testers type "192.168.1.5:3000" without a scheme; OkHttp would reject it.
            // Fail closed when blank — the form requires a server URL (no built-in default).
            val base = ServerUrls.normalize(serverUrl).ifBlank {
                throw IllegalArgumentException(getString(R.string.setup_error_server_url_required))
            }
            // Captured once: the claim body and the fingerprint recorded after Allow must describe the
            // same report, or a resume would re-send one the server already stored.
            val capabilityReport = capabilityReporter.report()
            val body = JSONObject()
                .put("code", code)
                .put("platform", "android")
                .put("model", Build.MODEL ?: "unknown")
                .put("osVersion", Build.VERSION.RELEASE ?: "unknown")
                .put("deviceName", deviceName.ifBlank { Build.MODEL ?: "android-device" })
                .apply { if (dataClearedDetected()) put("dataCleared", true) }
                // ADR-0034 A2: the same strict report a paired phone sends in telemetry. Absent when this
                // build cannot name itself, and the server then claims the phone without one rather than
                // refusing the claim.
                .apply { capabilityReport?.let { put("capabilities", JSONObject(it)) } }
                .toString()
                .toRequestBody(JSON_MEDIA_TYPE)
            val client = OkHttpClient.Builder()
                .connectTimeout(30, TimeUnit.SECONDS)
                .readTimeout(30, TimeUnit.SECONDS)
                .build()
            val request = Request.Builder().url("$base/v1/devices/pair/claim").post(body).build()
            val (claimId, pollSecret) = client.newCall(request).execute().use { response ->
                when (PairingApproval.claimStep(response.code)) {
                    PairingApproval.ClaimStep.WAITING_FOR_PARENT -> {
                        val json = JSONObject(response.body!!.string())
                        json.getString("claimId") to json.getString("pollSecret")
                    }
                    PairingApproval.ClaimStep.INVALID_CODE -> throw InvalidCodeException()
                    PairingApproval.ClaimStep.ALREADY_CLAIMED ->
                        throw PairingRefusedException(getString(R.string.pair_in_use))
                    PairingApproval.ClaimStep.CONSENT_REQUIRED ->
                        throw PairingRefusedException(getString(R.string.pair_consent))
                    PairingApproval.ClaimStep.FAILED ->
                        throw IllegalStateException(getString(R.string.setup_error_http, response.code))
                }
            }
            withContext(Dispatchers.Main) { onWaiting() }

            val pollBody = JSONObject().put("pollSecret", pollSecret).toString()
            var approved: String? = null
            val step = PairingApproval.awaitDecision(
                poll = {
                    val poll = Request.Builder()
                        .url("$base/v1/devices/pair/claims/$claimId/poll")
                        .post(pollBody.toRequestBody(JSON_MEDIA_TYPE))
                        .build()
                    client.newCall(poll).execute().use { response ->
                        if (response.code == 201) approved = response.body!!.string()
                        response.code
                    }
                },
                sleep = { delay(it) },
            )
            when (step) {
                PairingApproval.PollStep.APPROVED -> {
                    // #535 review (point 5): the report is stored with the device at Allow, so this is when it
                    // counts as accepted. Recorded only here: a claim the parent refuses must leave nothing
                    // behind, because nothing was stored.
                    capabilityReport?.let {
                        settings.recordReportedCapabilities(
                            com.familyshield.agent.capabilities.CapabilityUploadPolicy.fingerprint(it),
                        )
                    }
                    val json = JSONObject(approved!!)
                    val deviceId = when (val device = json.opt("device")) {
                        is JSONObject -> device.getString("id")
                        is String -> device
                        else -> throw IllegalStateException(getString(R.string.setup_error_no_device_id))
                    }
                    PairingResult(
                        baseUrl = base,
                        token = json.getString("token"),
                        deviceId = deviceId,
                        childId = json.getString("childId"),
                        // BUG-001: without the paired secret every /internal alert is a 401.
                        hmacSecret = json.optString("hmacSecret").ifBlank { null },
                    )
                }
                PairingApproval.PollStep.DENIED ->
                    throw PairingRefusedException(getString(R.string.pair_denied))
                PairingApproval.PollStep.EXPIRED, PairingApproval.PollStep.TIMED_OUT ->
                    throw PairingRefusedException(getString(R.string.pair_expired))
                PairingApproval.PollStep.CONSENT_REQUIRED ->
                    throw PairingRefusedException(getString(R.string.pair_consent))
                PairingApproval.PollStep.PENDING, PairingApproval.PollStep.FAILED ->
                    throw IllegalStateException(getString(R.string.setup_error_unfinished))
            }
        }

    private fun userMessage(e: Throwable): String = when (e) {
        is InvalidCodeException -> getString(R.string.pair_invalid_code)
        is PairingRefusedException -> e.message.orEmpty()
        else -> getString(R.string.pair_failed, e.message ?: getString(R.string.pair_network_error))
    }

    private fun requestLocationPermission() {
        val perms = if (Build.VERSION.SDK_INT >= 33) {
            arrayOf(
                android.Manifest.permission.ACCESS_FINE_LOCATION,
                android.Manifest.permission.ACCESS_COARSE_LOCATION,
                android.Manifest.permission.POST_NOTIFICATIONS,
            )
        } else {
            arrayOf(
                android.Manifest.permission.ACCESS_FINE_LOCATION,
                android.Manifest.permission.ACCESS_COARSE_LOCATION,
            )
        }
        locationPermissionLauncher.launch(perms)
    }

    private fun startLocationServiceIfPermitted() {
        // Issue #472: an unlinked phone has nothing to locate. Without this guard every launch after
        // an unlink started a location foreground service again — an ongoing notification on a device
        // the family was told it could uninstall.
        if (!settings.isPairedSync()) return
        val hasFine = ContextCompat.checkSelfPermission(this, android.Manifest.permission.ACCESS_FINE_LOCATION) == PackageManager.PERMISSION_GRANTED
        val hasCoarse = ContextCompat.checkSelfPermission(this, android.Manifest.permission.ACCESS_COARSE_LOCATION) == PackageManager.PERMISSION_GRANTED
        if (hasFine || hasCoarse) {
            try {
                // NOTE: this is a *foreground* start — the activity is resumed when it runs — so the
                // while-in-use grant is enough and ACCESS_BACKGROUND_LOCATION is not a precondition
                // (issue #132). Background start sites (BootReceiver, AccessibilityMonitorService,
                // CommandDispatcher) go through LocationStartPolicy; see LocationServiceStartSitesTest.
                ContextCompat.startForegroundService(this, Intent(this, LocationService::class.java))
            } catch (e: Exception) {
                android.util.Log.e("PairingActivity", "Failed to start LocationService", e)
            }
        }
    }

    /**
     * Issue #221 D3: the status screen's fix action. "Allow all the time" is a separate OS prompt on
     * Android 10+ and must be launched on its own, exactly as [locationPermissionLauncher] does after
     * the while-in-use grant.
     */
    private fun onLocationStatusAction(status: LocationStatus) {
        when (status) {
            LocationStatus.MISSING_PERMISSION -> requestLocationPermission()
            LocationStatus.MISSING_BACKGROUND ->
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                    backgroundLocationLauncher.launch(android.Manifest.permission.ACCESS_BACKGROUND_LOCATION)
                } else {
                    requestLocationPermission()
                }
            LocationStatus.SERVICE_STOPPED -> {
                startLocationServiceIfPermitted()
                lifecycleScope.launch {
                    kotlinx.coroutines.delay(500)
                    showStatus()
                }
            }
            LocationStatus.ACTIVE -> Unit
        }
    }

    /**
     * Starts LocationService (if permitted), schedules all periodic workers, and runs an immediate rules
     * sync and command poll.
     *
     * The poll is what moves the push token to the new device row (`CommandPoller` uploads it). The
     * periodic poll is `KEEP`, so on a re-pair it keeps its old schedule and does not run now; without
     * this fetch the token stayed on the old row, and the new row got no wake, until the next periodic
     * poll (Claude's #322 phone row, 2026-10-23).
     */
    private fun startAgent() {
        startLocationServiceIfPermitted()
        WorkScheduler.scheduleAll(this)
        CommandPollWorker.requestFetchNow(this)
    }

    private val childHomeSendState = androidx.compose.runtime.mutableStateOf(
        com.familyshield.agent.ui.home.TimeRequestSendState.IDLE,
    )
    private val childHomeCopyState = androidx.compose.runtime.mutableStateOf<com.familyshield.agent.ui.home.ChildHomeCopy?>(null)

    private fun sendChildHomeTimeRequest(minutes: Int) {
        if (childHomeSendState.value == com.familyshield.agent.ui.home.TimeRequestSendState.SENDING) return
        childHomeSendState.value = com.familyshield.agent.ui.home.TimeRequestSendState.SENDING
        val nowMs = System.currentTimeMillis()
        lifecycleScope.launch {
            val succeeded = com.familyshield.agent.ui.home.ChildHomePolicy.submitTimeRequest(
                minutes = minutes,
                nowMs = nowMs,
                postRequest = { allowed ->
                    kotlinx.coroutines.withContext(kotlinx.coroutines.Dispatchers.IO) {
                        runCatching {
                            api.postInternalAlert(
                                com.familyshield.agent.network.dto.AlertDto(
                                    childId = settings.childId(),
                                    deviceId = settings.deviceId(),
                                    severity = "info",
                                    category = "app_blocked",
                                    title = "Screen time requested",
                                    body = "Child asked for $allowed more minutes of screen time",
                                    metadata = mapOf(
                                        "requestType" to "time",
                                        "minutes" to allowed.toString(),
                                        "reason" to "daily_limit",
                                    ),
                                ),
                            )
                            Unit
                        }.onFailure { err ->
                            android.util.Log.w("PairingActivity", "C-01 time request failed", err)
                        }
                    }
                },
                persistPending = { pending ->
                    com.familyshield.agent.ui.home.ChildHomeStore.savePendingRequest(this@PairingActivity, pending)
                },
            )
            if (succeeded) {
                childHomeSendState.value = com.familyshield.agent.ui.home.TimeRequestSendState.IDLE
                childHomeCopyState.value = buildChildHomeCopy()
            } else {
                childHomeSendState.value = com.familyshield.agent.ui.home.TimeRequestSendState.FAILED
            }
        }
    }

    private fun formatChildHomeDuration(totalMinutes: Int): String {
        val safe = totalMinutes.coerceAtLeast(0)
        val hours = safe / 60
        val mins = safe % 60
        val hoursWestern = com.familyshield.agent.ui.home.ChildHomePolicy.formatWesternInt(hours)
        val minsWestern = com.familyshield.agent.ui.home.ChildHomePolicy.formatWesternInt(mins)
        return when {
            hours > 0 && mins > 0 -> getString(
                R.string.c01_hours_and_minutes,
                resources.getQuantityString(R.plurals.c01_hours, hours, hoursWestern),
                resources.getQuantityString(R.plurals.c01_minutes, mins, minsWestern),
            )
            hours > 0 -> resources.getQuantityString(R.plurals.c01_hours, hours, hoursWestern)
            else -> resources.getQuantityString(R.plurals.c01_minutes, mins, minsWestern)
        }
    }

    private fun buildChildHomeCopy(): com.familyshield.agent.ui.home.ChildHomeCopy {
        val now = java.time.ZonedDateTime.now()
        val nowMs = System.currentTimeMillis()
        val ruleSet = rules.cachedRules()
        val usageSnapshot = rules.minutesSnapshot()
        val storedDecisions = com.familyshield.agent.ui.home.ChildHomeStore.decisions(this)
        // G5 (#1191 B1): sum only today's accepted bonus_time grants; never read ruleSet.bonusMinutesToday.
        val bonusMinutes = com.familyshield.agent.ui.home.ChildHomePolicy.bonusMinutesForToday(storedDecisions, now)
        val isArabic = resources.configuration.locales[0]?.language == "ar"

        val adultNames = ruleSet?.adultNames.orEmpty()
        val adultsSpeaking = com.familyshield.agent.ui.home.AdultsNameFormatter.format(
            names = adultNames,
            fallback = getString(R.string.c01_adults_fallback_speaking),
            isArabic = isArabic,
        )
        val adultsAddressing = com.familyshield.agent.ui.home.AdultsNameFormatter.format(
            names = adultNames,
            fallback = getString(R.string.c01_adults_fallback_addressing),
            isArabic = isArabic,
        )

        val budget = com.familyshield.agent.ui.home.ChildHomePolicy.timeBudget(
            ruleSet = ruleSet,
            now = now,
            minutesUsedToday = usageSnapshot,
            localBonusMinutes = bonusMinutes,
        )
        val windDownMins = com.familyshield.agent.ui.home.ChildHomeStore.windDownMinutesLeft(this, nowMs)
        val nextRoutine = com.familyshield.agent.ui.home.ChildHomePolicy.nextRoutine(ruleSet, now)
        val bedtime = com.familyshield.agent.ui.home.ChildHomePolicy.bedtimeStart(ruleSet)
            ?.let { com.familyshield.agent.ui.home.AdultsNameFormatter.ltrIsolate(it) }

        val pending = com.familyshield.agent.ui.home.ChildHomeStore.pendingRequest(this)
        val pendingState = com.familyshield.agent.ui.home.ChildHomePolicy.pendingStatus(pending, nowMs)
        val pendingTitle = when {
            pending == null || pendingState == com.familyshield.agent.ui.home.PendingRequestStatus.NONE -> null
            pending.requestType == "time" -> getString(
                R.string.c01_pending_time_title,
                com.familyshield.agent.ui.home.ChildHomePolicy.formatWesternInt(pending.minutes ?: 15),
            )
            else -> getString(
                R.string.c01_pending_access_title,
                com.familyshield.agent.ui.home.AdultsNameFormatter.firstStrongIsolate(pending.appLabel ?: getString(R.string.app_name)),
            )
        }
        val pendingSentLine = if (pending != null && pendingTitle != null) {
            val hhMm = com.familyshield.agent.ui.home.AdultsNameFormatter.ltrIsolate(
                com.familyshield.agent.ui.home.ChildHomePolicy.formatClockHhMm(pending.sentAtMs),
            )
            getString(R.string.c01_sent_to_line, adultsSpeaking, hhMm)
        } else {
            null
        }
        val pendingBadge = when (pendingState) {
            com.familyshield.agent.ui.home.PendingRequestStatus.WAITING -> getString(R.string.c01_waiting_reply)
            com.familyshield.agent.ui.home.PendingRequestStatus.NO_ANSWER_YET -> getString(R.string.c01_no_answer_yet)
            com.familyshield.agent.ui.home.PendingRequestStatus.NONE -> null
        }

        val decisionsUi = storedDecisions.map { item ->
            val timeStr = com.familyshield.agent.ui.home.AdultsNameFormatter.ltrIsolate(
                com.familyshield.agent.ui.home.ChildHomePolicy.formatClockHhMm(item.timestampMs),
            )
            val title = when (item.kind) {
                "bonus_time" -> {
                    val minsWestern = com.familyshield.agent.ui.home.ChildHomePolicy.formatWesternInt(item.minutes ?: 15)
                    if (!item.byName.isNullOrBlank()) {
                        getString(
                            R.string.c01_decision_bonus_named,
                            minsWestern,
                            com.familyshield.agent.ui.home.AdultsNameFormatter.firstStrongIsolate(item.byName),
                        )
                    } else {
                        getString(R.string.c01_decision_bonus_unnamed, minsWestern)
                    }
                }
                "pause_internet" -> getString(R.string.c01_decision_pause_internet)
                "resume_internet" -> getString(R.string.c01_decision_resume_internet)
                else -> getString(R.string.c01_decision_rules_updated)
            }
            val badge = if (item.todayOnly) {
                getString(R.string.c01_badge_today_only)
            } else {
                getString(R.string.c01_badge_working_on_phone)
            }
            com.familyshield.agent.ui.home.ChildDecisionItemUi(
                title = title,
                subtitle = timeStr,
                badge = badge,
            )
        }

        val activityItems = usageSnapshot.entries
            .filter { it.value > 0 }
            .sortedByDescending { it.value }
            .take(10)
            .map { (pkg, mins) ->
                val resolved = runCatching {
                    packageManager.getApplicationLabel(packageManager.getApplicationInfo(pkg, 0)).toString()
                }.getOrNull()?.takeIf { it.isNotBlank() } ?: pkg
                com.familyshield.agent.ui.home.ChildActivityItemUi(
                    appName = com.familyshield.agent.ui.home.AdultsNameFormatter.firstStrongIsolate(resolved),
                    durationText = formatChildHomeDuration(mins),
                )
            }

        val hasLimit = budget.effectiveLimitMinutes != null && budget.remainingMinutes != null
        val ringNumber = com.familyshield.agent.ui.home.ChildHomePolicy.formatWesternInt(budget.remainingMinutes ?: 0)
        val timeLeftHeadline = if (hasLimit) {
            getString(R.string.c01_time_left_today, formatChildHomeDuration(budget.remainingMinutes!!))
        } else {
            getString(R.string.c01_no_daily_limit)
        }
        val usedOfLimitLine = if (hasLimit) {
            getString(
                R.string.c01_used_of_limit,
                formatChildHomeDuration(budget.usedMinutes),
                formatChildHomeDuration(budget.effectiveLimitMinutes!!),
            )
        } else {
            getString(R.string.c01_used_today_only, formatChildHomeDuration(budget.usedMinutes))
        }

        val nextRoutineLine = if (nextRoutine != null) {
            getString(
                R.string.c01_next_routine_line,
                com.familyshield.agent.ui.home.AdultsNameFormatter.firstStrongIsolate(nextRoutine.name),
                com.familyshield.agent.ui.home.AdultsNameFormatter.ltrIsolate(nextRoutine.startHhMm),
                formatChildHomeDuration(nextRoutine.startsInMinutes),
            )
        } else {
            getString(R.string.c01_next_routine_none)
        }

        val headerTitle = getString(R.string.c01_header_title)
        val avatarInitial = headerTitle.trim().firstOrNull()?.uppercaseChar()?.toString() ?: "O"

        return com.familyshield.agent.ui.home.ChildHomeCopy(
            avatarInitial = avatarInitial,
            headerTitle = headerTitle,
            callParentLabel = getString(R.string.c01_call_parent),
            windDownBanner = windDownMins?.let { getString(R.string.c01_wind_down_banner, formatChildHomeDuration(it)) },
            hasDailyLimit = hasLimit,
            ringNumber = com.familyshield.agent.ui.home.AdultsNameFormatter.ltrIsolate(ringNumber),
            ringUnit = getString(R.string.c01_ring_unit_min),
            ringFraction = budget.remainingFraction,
            timeLeftHeadline = timeLeftHeadline,
            usedOfLimitLine = usedOfLimitLine,
            askMoreTimeLabel = getString(R.string.c01_ask_more_time),
            nextLabel = getString(R.string.c01_next_label),
            nextRoutineLine = nextRoutineLine,
            bedtimeLabel = getString(R.string.c01_bedtime_label),
            bedtimeValue = bedtime,
            pendingTitle = pendingTitle,
            pendingSentLine = pendingSentLine,
            pendingBadge = pendingBadge,
            pendingIsWaiting = pendingState == com.familyshield.agent.ui.home.PendingRequestStatus.WAITING,
            latestSectionLabel = getString(R.string.c01_latest_from_adults, adultsSpeaking),
            seeAllLabel = getString(R.string.c01_see_all),
            latestDecision = decisionsUi.firstOrNull(),
            whatAdultsSeeTitle = getString(R.string.c01_what_adults_see, adultsSpeaking),
            whatAdultsSeeSubtitle = getString(R.string.c01_rules_and_shared),
            myActivityTitle = getString(R.string.c01_my_activity),
            myActivitySubtitle = getString(R.string.c01_same_numbers, adultsSpeaking),
            openLabel = getString(R.string.c01_open),
            sendSosLabel = getString(R.string.c01_send_sos, adultsSpeaking),
            tabTodayLabel = getString(R.string.c01_tab_today),
            tabRequestsLabel = getString(R.string.c01_tab_requests),
            tabMessagesLabel = getString(R.string.c01_tab_messages),
            requestsHeaderTitle = getString(R.string.c01_requests_title),
            requestsGoesToLine = getString(R.string.c01_goes_to, adultsAddressing),
            request15Label = getString(R.string.c01_request_15_min),
            request30Label = getString(R.string.c01_request_30_min),
            requestsDisabledLine = getString(R.string.c01_requests_no_limit),
            requestFailedLine = getString(R.string.c01_request_failed),
            messagesHeaderTitle = getString(R.string.c01_messages_title),
            messagesEmptyLine = getString(R.string.c01_messages_empty, adultsSpeaking),
            allDecisions = decisionsUi,
            transparencyLines = listOf(
                getString(R.string.c01_transparency_apps),
                getString(R.string.c01_transparency_location),
                getString(R.string.c01_transparency_safety, adultsAddressing),
            ),
            openDeviceSetupLabel = getString(R.string.c01_open_device_setup),
            activityItems = activityItems,
            activityEmptyLine = getString(R.string.c01_activity_empty),
            dialogCloseLabel = getString(R.string.c01_close),
        )
    }

    // ---- view helpers ----

    private fun replaceWith(build: LinearLayout.() -> Unit) {
        accessibilityBindObserver.stop()
        val pad = (16 * resources.displayMetrics.density).toInt()
        root.setPadding(pad, pad, pad, pad)
        root.removeAllViews()
        root.build()
    }

    private fun replaceWithCompose(content: @androidx.compose.runtime.Composable () -> Unit) {
        accessibilityBindObserver.stop()
        root.setPadding(0, 0, 0, 0)
        root.removeAllViews()
        root.addView(
            ComposeView(this).apply {
                setViewCompositionStrategy(ViewCompositionStrategy.DisposeOnViewTreeLifecycleDestroyed)
                layoutParams = LinearLayout.LayoutParams(
                    LinearLayout.LayoutParams.MATCH_PARENT,
                    LinearLayout.LayoutParams.MATCH_PARENT,
                )
                setContent {
                    OsraTheme.OsraTheme {
                        content()
                    }
                }
            },
            LinearLayout.LayoutParams(
                LinearLayout.LayoutParams.MATCH_PARENT,
                LinearLayout.LayoutParams.MATCH_PARENT,
                1f,
            ),
        )
    }

    private fun label(text: String): TextView = TextView(this).apply { this.text = text }

    private fun renderC05Agreement(rows: List<OnboardingPolicy.Row>, ruleSet: RuleSetDto?) {
        val brand = "${getString(R.string.app_name)} · ${getString(R.string.app_name_ar)}"
        val noticeRes = OnboardingPolicy.captureNoticeRes(
            BuildConfig.CAPTURE_NOTIFICATIONS,
            BuildConfig.CAPTURE_CALL_SMS,
        )
        val copy = FamilyAgreementCopy(
            brandLabel = brand,
            stepBadge = getString(R.string.c05_step_badge_3),
            title = getString(R.string.c05_agreement_title),
            body = getString(R.string.c05_agreement_body),
            progressLine = progressLine(rows),
            rulesCard = buildFamilyRulesCard(ruleSet),
            captureNotice = noticeRes?.let { getString(it) },
            optionalCallSmsPrompt = if (BuildConfig.CAPTURE_CALL_SMS) getString(R.string.setup_call_sms_invite) else null,
            optionalCallSmsButton = if (BuildConfig.CAPTURE_CALL_SMS) getString(R.string.setup_grant_call_sms) else null,
            finishButton = getString(R.string.c05_agreement_finish),
        )
        replaceWithCompose {
            OnboardingFamilyAgreementScreen(
                copy = copy,
                onGrantCallSms = if (BuildConfig.CAPTURE_CALL_SMS) {
                    { commsPermissionLauncher.launch(COMMS_PERMISSIONS) }
                } else {
                    null
                },
                onFinish = { finishGuidedSetupAndShowStatus() },
            )
        }
    }

    /**
     * C-05 (#1208 B2): builds the real family rules summary from the cached [RuleSetDto] (daily
     * limit, bedtime, school hours, blocked categories). Returns null when there are no cached
     * rules so the agreement screen hides the section instead of repeating "What OSRA checks".
     */
    private fun buildFamilyRulesCard(ruleSet: RuleSetDto?): FamilyRulesCardCopy? {
        val summary = OnboardingPolicy.agreementRulesSummary(ruleSet) ?: return null
        val items = buildList {
            summary.dailyLimitMinutes?.let { mins ->
                add(
                    FamilyRuleItemCopy(
                        label = getString(R.string.c05_rule_daily_limit_title),
                        value = formatRuleDuration(mins),
                    ),
                )
            }
            if (summary.bedtimeStart != null && summary.bedtimeEnd != null) {
                add(
                    FamilyRuleItemCopy(
                        label = getString(R.string.block_window_bedtime),
                        value = getString(R.string.c05_rule_time_window, summary.bedtimeStart, summary.bedtimeEnd),
                    ),
                )
            }
            if (summary.schoolStart != null && summary.schoolEnd != null) {
                add(
                    FamilyRuleItemCopy(
                        label = getString(R.string.block_window_school),
                        value = getString(R.string.c05_rule_time_window, summary.schoolStart, summary.schoolEnd),
                    ),
                )
            }
            if (summary.blockedCategories.isNotEmpty()) {
                val sep = getString(R.string.list_separator)
                val labels = summary.blockedCategories.joinToString(sep) { slug ->
                    OnboardingPolicy.webCategoryLabelRes(slug)?.let { getString(it) } ?: slug
                }
                add(
                    FamilyRuleItemCopy(
                        label = getString(R.string.c05_rule_blocked_categories_title),
                        value = labels,
                    ),
                )
            }
        }
        return items.takeIf { it.isNotEmpty() }?.let { FamilyRulesCardCopy(it) }
    }

    private fun formatRuleDuration(totalMinutes: Int): String {
        val hours = totalMinutes / 60
        val minutes = totalMinutes % 60
        val hoursStr = if (hours > 0) {
            resources.getQuantityString(
                R.plurals.c05_rule_hours,
                hours,
                OnboardingPolicy.formatWesternInt(hours),
            )
        } else {
            null
        }
        val minsStr = if (minutes > 0 || hours == 0) {
            resources.getQuantityString(
                R.plurals.c05_rule_minutes,
                minutes,
                OnboardingPolicy.formatWesternInt(minutes),
            )
        } else {
            null
        }
        return when {
            hoursStr != null && minsStr != null -> getString(R.string.c05_rule_hours_and_minutes, hoursStr, minsStr)
            hoursStr != null -> hoursStr
            else -> minsStr.orEmpty()
        }
    }

    /** The header line, resolved in the phone's language with Western digits (#1208 Arabic Bureau). */
    private fun progressLine(rows: List<OnboardingPolicy.Row>): String =
        OnboardingPolicy.progressLineRes(rows).let { line ->
            if (line.textRes == R.string.onboarding_progress_complete) {
                getString(line.textRes)
            } else {
                getString(
                    line.textRes,
                    OnboardingPolicy.formatWesternInt(line.done),
                    OnboardingPolicy.formatWesternInt(line.total),
                )
            }
        }

    private fun editText(initial: String, inputType: Int): EditText =
        EditText(this).apply {
            setText(initial)
            this.inputType = inputType
        }

    private fun labeled(caption: String, field: EditText): LinearLayout =
        LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            addView(label(caption))
            addView(field)
        }

    private class InvalidCodeException : Exception()

    /** A pairing that ended for a reason the person can act on; [message] says what to do. */
    private class PairingRefusedException(message: String) : Exception(message)

    private data class PairingResult(
        val baseUrl: String,
        val token: String,
        val deviceId: String,
        val childId: String,
        val hmacSecret: String?,
    )

    companion object {
        private val JSON_MEDIA_TYPE = "application/json; charset=utf-8".toMediaType()

        /** Roadmap 3.2: the reviewed payload survives an activity recreation. */
        private const val KEY_SCANNED_QR = "scanned_pair_qr"

        /** #433 review (c): what the person typed survives a fold or a rotation. */
        private const val KEY_TYPED_SERVER = "typed_pair_server"
        private const val KEY_TYPED_CODE = "typed_pair_code"
        private const val KEY_TYPED_NAME = "typed_pair_name"
        private const val KEY_WELCOME_COMPLETED = "welcome_completed"
        private const val KEY_GUIDED_STAGE = "guided_stage"
        private const val KEY_GUIDED_FIRST_RUN = "guided_first_run"
        private const val KEY_FORCE_CHECKLIST_VIEW = "force_checklist_view"
        private const val KEY_SKIPPED_GRANTS = "skipped_permission_grants"

        /** Feature #6 runtime permissions (declared in the manifest; prompted, not required). */
        private val COMMS_PERMISSIONS = arrayOf(
            android.Manifest.permission.READ_CALL_LOG,
            android.Manifest.permission.READ_SMS,
        )
    }
}
