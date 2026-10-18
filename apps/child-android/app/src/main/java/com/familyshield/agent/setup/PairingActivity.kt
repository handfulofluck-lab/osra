package com.familyshield.agent.setup

import com.familyshield.agent.BuildConfig
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import android.os.Bundle
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
import androidx.core.content.ContextCompat
import androidx.lifecycle.lifecycleScope
import com.familyshield.agent.data.AgentSettings
import com.familyshield.agent.data.WorkScheduler
import com.familyshield.agent.network.ServerUrls
import com.familyshield.agent.security.DeviceAdminManager
import com.familyshield.agent.security.ParentPin
import com.familyshield.agent.security.ParentPinStore
import com.familyshield.agent.security.ProtectionTier
import com.familyshield.agent.security.TamperGuardActivity
import com.familyshield.agent.services.LocationService
import dagger.hilt.android.AndroidEntryPoint
import java.util.concurrent.TimeUnit
import javax.inject.Inject
import kotlinx.coroutines.Dispatchers
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
    @Inject lateinit var pinStore: ParentPinStore
    @Inject lateinit var deviceAdmin: DeviceAdminManager

    /** ADR-0010: the OS "activate device admin" screen; whatever the answer, continue to the status screen. */
    private val deviceAdminLauncher = registerForActivityResult(ActivityResultContracts.StartActivityForResult()) {
        deviceAdmin.applyUninstallProtection()
        lifecycleScope.launch { if (settings.isPaired()) showStatus() else showComplete() }
    }

    /** Plan 1.4: the OS VPN consent dialog; on OK the sinkhole starts and comes back on every boot. */
    private val vpnConsentLauncher = registerForActivityResult(ActivityResultContracts.StartActivityForResult()) { result ->
        if (result.resultCode == RESULT_OK) {
            com.familyshield.agent.vpn.VpnState.setEnabled(this, true)
            com.familyshield.agent.vpn.FilterVpnService.start(this)
        }
        lifecycleScope.launch { if (settings.isPaired()) showStatus() else showComplete() }
    }

    /** ADR-0010: parent-PIN gate for Re-pair / Remove protection; RESULT_OK means the PIN was verified. */
    private var pendingGuardedAction: (() -> Unit)? = null
    private val guardLauncher = registerForActivityResult(ActivityResultContracts.StartActivityForResult()) { result ->
        val action = pendingGuardedAction
        pendingGuardedAction = null
        if (result.resultCode == RESULT_OK) action?.invoke()
    }

    // NOTE: READ_CALL_LOG/READ_SMS are dangerous permissions; the request is optional (the agent
    // stays in log-only skip mode without them) so pairing never blocks on it.
    private val commsPermissionLauncher = registerForActivityResult(
        ActivityResultContracts.RequestMultiplePermissions(),
    ) { /* granted or not, CommsLogger starts harvesting once permission exists */ }

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
            if (settings.isPaired()) showStatus() else showComplete()
        }
    }

    private val backgroundLocationLauncher = registerForActivityResult(ActivityResultContracts.RequestPermission()) {
        lifecycleScope.launch { if (settings.isPaired()) showStatus() else showComplete() }
    }

    /** Plan 1.6: live grant state, asked of the OS on every render. */
    private val grants: GrantChecks by lazy { GrantChecks(this, deviceAdmin) }

    private lateinit var root: LinearLayout

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        root = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            val pad = (16 * resources.displayMetrics.density).toInt()
            setPadding(pad, pad, pad, pad)
        }
        setContentView(root)
        showLoading()
        // NOTE: reading the token (not the cache) — a fresh process has empty caches.
        lifecycleScope.launch { if (settings.isPaired()) showStatus() else showForm() }
    }

    override fun onResume() {
        super.onResume()
        lifecycleScope.launch {
            if (settings.isPaired()) {
                startLocationServiceIfPermitted()
                showStatus()
            }
        }
    }

    // ---- states ----

    private fun showLoading() {
        replaceWith {
            addView(label("OSRA Child Agent"))
            addView(ProgressBar(this@PairingActivity))
        }
    }

    private fun showForm() {
        replaceWith {
            addView(label("OSRA Child Agent"))
            addView(label("Pair this device with your OSRA server."))

            val server = editText("", InputType.TYPE_TEXT_VARIATION_URI).apply {
                hint = "https://your-server or 192.168.1.5:3000"
            }
            val code = editText("", InputType.TYPE_CLASS_NUMBER).apply {
                filters = arrayOf(InputFilter.LengthFilter(6))
                hint = "6-digit pairing code"
            }
            val name = editText("", InputType.TYPE_TEXT_FLAG_CAP_WORDS).apply { hint = "Device name (optional)" }
            val error = label("").apply {
                setTextColor(0xFFB00020.toInt())
                visibility = View.GONE
            }
            val pairButton = Button(this@PairingActivity).apply { text = "Pair this device" }
            val progress = ProgressBar(this@PairingActivity).apply { visibility = View.GONE }

            pairButton.setOnClickListener {
                val enteredServer = server.text.toString().trim()
                if (enteredServer.isBlank()) {
                    error.text = "Enter the server URL from your parent."
                    error.visibility = View.VISIBLE
                    return@setOnClickListener
                }
                val enteredCode = code.text.toString().trim()
                if (!enteredCode.matches(Regex("\\d{6}"))) {
                    error.text = "Enter the 6-digit pairing code."
                    error.visibility = View.VISIBLE
                    return@setOnClickListener
                }
                pairButton.isEnabled = false
                progress.visibility = View.VISIBLE
                error.visibility = View.GONE
                val deviceName = name.text.toString().trim()
                lifecycleScope.launch {
                    val result = runCatching { claim(enteredServer, enteredCode, deviceName) }
                    pairButton.isEnabled = true
                    progress.visibility = View.GONE
                    result.onSuccess { pairing ->
                        settings.savePairing(pairing.baseUrl, pairing.token, pairing.deviceId, pairing.childId, pairing.hmacSecret)
                        startAgent()
                        // ADR-0010: the parent is holding the phone right now — this is the moment to set the PIN
                        // that gates every protection-removal action from here on.
                        if (pinStore.isConfigured()) showProtectionSetup() else showSetPin()
                    }.onFailure { e ->
                        error.text = userMessage(e)
                        error.visibility = View.VISIBLE
                    }
                }
            }

            addView(labeled("Server URL", server))
            addView(labeled("Pairing code", code))
            addView(labeled("Device name", name))
            addView(pairButton)
            addView(progress)
            addView(error)
        }
    }

    /** ADR-0010 step 1: the parent chooses the PIN (4–8 digits, not a weak one). */
    private fun showSetPin() {
        replaceWith {
            addView(label("Paired. Now set the parent PIN · أسرة"))
            addView(
                label(
                    "This PIN is asked for whenever someone tries to remove OSRA's protection on this device " +
                        "(turn off device admin, uninstall, re-pair). Keep it to yourself — your child must not know it.",
                ),
            )
            val pin = editText("", InputType.TYPE_CLASS_NUMBER or InputType.TYPE_NUMBER_VARIATION_PASSWORD).apply {
                hint = "4–8 digits"
                filters = arrayOf(InputFilter.LengthFilter(ParentPin.MAX_LENGTH))
            }
            val again = editText("", InputType.TYPE_CLASS_NUMBER or InputType.TYPE_NUMBER_VARIATION_PASSWORD).apply {
                hint = "Repeat the PIN"
                filters = arrayOf(InputFilter.LengthFilter(ParentPin.MAX_LENGTH))
            }
            val error = TextView(this@PairingActivity).apply { setTextColor(0xFFB00020.toInt()); visibility = View.GONE }
            addView(labeled("Parent PIN", pin))
            addView(labeled("Repeat", again))
            addView(
                Button(this@PairingActivity).apply {
                    text = "Save PIN"
                    setOnClickListener {
                        val p = pin.text.toString()
                        val reason = ParentPin.validationError(p) ?: if (p != again.text.toString()) "The two PINs differ." else null
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
        if (deviceAdmin.isAdminActive()) {
            deviceAdmin.applyUninstallProtection()
            showComplete()
            return
        }
        replaceWith {
            addView(label("Protect this device · أسرة"))
            addView(
                label(
                    "On the next screen, tap \"Activate\" to give OSRA device-admin rights. With it, this app " +
                        "cannot be uninstalled without the parent PIN and your parent can lock the device remotely. " +
                        "Without it, protection is alert-only.",
                ),
            )
            addView(
                Button(this@PairingActivity).apply {
                    text = "Activate device admin"
                    setOnClickListener { deviceAdminLauncher.launch(deviceAdmin.requestAdminIntent()) }
                },
            )
            addView(
                Button(this@PairingActivity).apply {
                    text = "Skip for now (alert-only protection)"
                    setOnClickListener { showComplete() }
                },
            )
        }
    }

    /** Runs [action] only after the parent PIN is verified on the guard screen; no PIN yet → runs at once. */
    private fun requirePin(reason: String, action: () -> Unit) {
        if (!pinStore.isConfigured()) { action(); return }
        pendingGuardedAction = action
        guardLauncher.launch(Intent(this, TamperGuardActivity::class.java).putExtra(TamperGuardActivity.EXTRA_REASON, reason))
    }

    private fun showComplete() {
        val rows = OnboardingPolicy.rows(BuildConfig.CAPTURE_NOTIFICATIONS) { grants.isGranted(it) }
        if (!OnboardingPolicy.canComplete(rows)) { showChecklist(rows, firstRun = true); return }
        replaceWith {
            addView(label("Setup complete"))
            addView(label(OnboardingPolicy.progressLine(rows)).apply { setTextColor(0xFF2E7D32.toInt()) })
            addView(label("The agent is now monitoring this device."))
            for (row in rows.filter { !it.granted }) addGrantRow(this, row) // the recommended ones still open
            addView(
                label(
                    "Optional: grant Call Log and SMS permissions so calls and messages are " +
                        "logged for safety review (log-only; the agent never becomes the default dialer).",
                ),
            )
            addView(
                Button(this@PairingActivity).apply {
                    text = "Grant call & SMS permissions"
                    setOnClickListener { commsPermissionLauncher.launch(COMMS_PERMISSIONS) }
                },
            )
            addView(Button(this@PairingActivity).apply { text = "Open status"; setOnClickListener { lifecycleScope.launch { showStatus() } } })
        }
    }

    /**
     * Plan 1.6: the guided checklist. Every grant is a row with its reason, the OEM hint when there is
     * one, and a button that opens exactly the screen that grants it; the rows are re-asked of the OS
     * on every resume, so coming back from Settings without granting leaves the row red. Pairing is
     * not "complete" (and the status screen says so) until the required rows are green.
     */
    private fun showChecklist(rows: List<OnboardingPolicy.Row>, firstRun: Boolean) {
        replaceWith {
            addView(label(if (firstRun) "Finish protecting this device · أسرة" else "Protection checklist · أسرة"))
            addView(
                label(OnboardingPolicy.progressLine(rows)).apply {
                    setTextColor(if (OnboardingPolicy.canComplete(rows)) 0xFF2E7D32.toInt() else 0xFFB00020.toInt())
                },
            )
            if (firstRun) addView(label("Each item below opens the one screen that grants it. Come back here after each one; the list re-checks itself."))
            for (row in rows) addGrantRow(this, row)
            if (!firstRun) {
                addView(Button(this@PairingActivity).apply { text = "Back"; setOnClickListener { lifecycleScope.launch { showStatus() } } })
            } else if (OnboardingPolicy.canComplete(rows)) {
                addView(Button(this@PairingActivity).apply { text = "Done"; setOnClickListener { showComplete() } })
            }
        }
    }

    private fun addGrantRow(container: LinearLayout, row: OnboardingPolicy.Row) {
        val g = row.grant
        val mark = if (row.granted) "✓" else if (g.required) "⚠️" else "○"
        val suffix = if (g.required) "" else " (recommended)"
        container.addView(
            label("$mark ${g.title}$suffix").apply {
                setTextColor(if (row.granted) 0xFF2E7D32.toInt() else if (g.required) 0xFFB00020.toInt() else 0xFF616161.toInt())
            },
        )
        if (row.granted) return
        container.addView(label(g.why))
        OnboardingPolicy.oemHint(g, Build.MANUFACTURER)?.let { container.addView(label(it)) }
        val button = Button(this).apply { text = "Grant: ${g.title}" }
        when (g) {
            OnboardingPolicy.Grant.DEVICE_ADMIN -> button.setOnClickListener { deviceAdminLauncher.launch(deviceAdmin.requestAdminIntent()) }
            OnboardingPolicy.Grant.WEB_FILTER -> button.setOnClickListener {
                val prepare = android.net.VpnService.prepare(this)
                if (prepare != null) vpnConsentLauncher.launch(prepare) else {
                    com.familyshield.agent.vpn.VpnState.setEnabled(this, true)
                    com.familyshield.agent.vpn.FilterVpnService.start(this)
                    lifecycleScope.launch { if (settings.isPaired()) showStatus() else showComplete() }
                }
            }
            OnboardingPolicy.Grant.LOCATION -> button.setOnClickListener {
                val hasAny = ContextCompat.checkSelfPermission(this, android.Manifest.permission.ACCESS_FINE_LOCATION) == PackageManager.PERMISSION_GRANTED
                if (hasAny && Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) backgroundLocationLauncher.launch(android.Manifest.permission.ACCESS_BACKGROUND_LOCATION)
                else requestLocationPermission()
            }
            else -> button.setOnClickListener { grants.fixIntent(g)?.let { runCatching { startActivity(it) } } }
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
                label("⚠️ Web filter not set up — allow the OSRA VPN (it only filters web addresses on this phone; nothing leaves the device).").apply {
                    setTextColor(0xFFB00020.toInt())
                },
            )
            container.addView(
                Button(this).apply {
                    text = "Set up web filter"
                    setOnClickListener { vpnConsentLauncher.launch(prepare) }
                },
            )
            return
        }
        if (!com.familyshield.agent.vpn.VpnState.isEnabled(this)) {
            com.familyshield.agent.vpn.VpnState.setEnabled(this, true)
        }
        if (com.familyshield.agent.vpn.VpnState.isEstablished(this)) {
            container.addView(label("✓ Web filter: connected (SafeSearch, blocked sites, pause-internet)"))
        } else {
            container.addView(
                label("⚠️ Web filter: not connected").apply { setTextColor(0xFFB00020.toInt()) },
            )
            container.addView(
                Button(this).apply {
                    text = "Reconnect web filter"
                    setOnClickListener {
                        com.familyshield.agent.vpn.FilterVpnService.start(this@PairingActivity)
                        lifecycleScope.launch { kotlinx.coroutines.delay(800); if (settings.isPaired()) showStatus() }
                    }
                },
            )
        }
    }

    private fun showStatus() {
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

            val tier = deviceAdmin.tier()
            replaceWith {
                addView(label("This device is paired · أسرة"))
                addView(label("Child: $childId\nDevice: $deviceId\nServer: $server"))
                addView(
                    label(
                        when (tier) {
                            ProtectionTier.OWNER -> "\n✓ Protection: device owner (uninstall blocked by the OS)"
                            ProtectionTier.ADMIN -> "\n✓ Protection: device admin (uninstall needs the parent PIN)"
                            ProtectionTier.NONE -> "\n⚠️ Protection: alert-only — device admin is not active"
                        },
                    ).apply { setTextColor(if (tier == ProtectionTier.NONE) 0xFFB00020.toInt() else 0xFF2E7D32.toInt()) },
                )
                if (tier == ProtectionTier.NONE) {
                    addView(
                        Button(this@PairingActivity).apply {
                            text = "Activate device admin"
                            setOnClickListener { deviceAdminLauncher.launch(deviceAdmin.requestAdminIntent()) }
                        },
                    )
                }
                if (!pinStore.isConfigured()) {
                    addView(
                        Button(this@PairingActivity).apply {
                            text = "Set parent PIN"
                            setOnClickListener { showSetPin() }
                        },
                    )
                }

                if (!hasLocation) {
                    addView(
                        label("\n⚠️ Location permission is required for live GPS tracking and geofence alerts.").apply {
                            setTextColor(0xFFB00020.toInt())
                        },
                    )
                    addView(
                        Button(this@PairingActivity).apply {
                            text = "Grant location permission"
                            setOnClickListener { requestLocationPermission() }
                        },
                    )
                } else if (!isRunning) {
                    addView(
                        label("\n⚠️ Location service is not running.").apply {
                            setTextColor(0xFFE65100.toInt())
                        },
                    )
                    addView(
                        Button(this@PairingActivity).apply {
                            text = "Start location service"
                            setOnClickListener {
                                startLocationServiceIfPermitted()
                                lifecycleScope.launch {
                                    kotlinx.coroutines.delay(500)
                                    showStatus()
                                }
                            }
                        },
                    )
                } else {
                    addView(
                        label("\n✓ Location tracking: Active").apply {
                            setTextColor(0xFF2E7D32.toInt())
                        },
                    )
                }

                addView(
                    Button(this@PairingActivity).apply {
                        text = "Open accessibility settings"
                        setOnClickListener { startActivity(Intent(Settings.ACTION_ACCESSIBILITY_SETTINGS)) }
                    },
                )
                val rows = OnboardingPolicy.rows(BuildConfig.CAPTURE_NOTIFICATIONS) { grants.isGranted(it) }
                val missing = OnboardingPolicy.missingRequired(rows)
                addView(
                    label("\n" + OnboardingPolicy.progressLine(rows) + if (missing.isEmpty()) "" else "\nMissing: " + missing.joinToString { it.title }).apply {
                        setTextColor(if (missing.isEmpty()) 0xFF2E7D32.toInt() else 0xFFB00020.toInt())
                    },
                )
                addView(
                    Button(this@PairingActivity).apply {
                        text = if (missing.isEmpty()) "Protection checklist" else "Finish protection (${missing.size} to grant)"
                        setOnClickListener { showChecklist(OnboardingPolicy.rows(BuildConfig.CAPTURE_NOTIFICATIONS) { grants.isGranted(it) }, firstRun = false) }
                    },
                )
                addWebFilterRow(this)
                addView(
                    Button(this@PairingActivity).apply {
                        text = "Re-pair (parent PIN)"
                        setOnClickListener {
                            requirePin(TamperGuardActivity.REASON_REPAIR) {
                                lifecycleScope.launch {
                                    settings.clearPairing()
                                    showForm()
                                }
                            }
                        }
                    },
                )
                addView(
                    Button(this@PairingActivity).apply {
                        text = "Remove protection (parent PIN)"
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

    /** Posts the claim request on IO; throws [InvalidCodeException] on 404. */
    private suspend fun claim(serverUrl: String, code: String, deviceName: String): PairingResult =
        withContext(Dispatchers.IO) {
            // NOTE: testers type "192.168.1.5:3000" without a scheme; OkHttp would reject it.
            // Fail closed when blank — the form requires a server URL (no built-in default).
            val base = ServerUrls.normalize(serverUrl).ifBlank { throw IllegalArgumentException("Server URL is required") }
            val body = JSONObject()
                .put("code", code)
                .put("platform", "android")
                .put("model", Build.MODEL ?: "unknown")
                .put("osVersion", Build.VERSION.RELEASE ?: "unknown")
                .put("deviceName", deviceName.ifBlank { Build.MODEL ?: "android-device" })
                .toString()
                .toRequestBody(JSON_MEDIA_TYPE)
            val client = OkHttpClient.Builder()
                .connectTimeout(30, TimeUnit.SECONDS)
                .readTimeout(30, TimeUnit.SECONDS)
                .build()
            val request = Request.Builder().url("$base/v1/devices/pair/claim").post(body).build()
            client.newCall(request).execute().use { response ->
                when (response.code) {
                    201 -> {
                        val json = JSONObject(response.body!!.string())
                        val deviceId = when (val device = json.opt("device")) {
                            is JSONObject -> device.getString("id")
                            is String -> device
                            else -> throw IllegalStateException("pairing response has no device id")
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
                    404 -> throw InvalidCodeException()
                    else -> throw IllegalStateException("server returned HTTP ${response.code}")
                }
            }
        }

    private fun userMessage(e: Throwable): String = when (e) {
        is InvalidCodeException -> "Invalid or expired pairing code."
        else -> "Pairing failed: ${e.message ?: "network error"}"
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
        val hasFine = ContextCompat.checkSelfPermission(this, android.Manifest.permission.ACCESS_FINE_LOCATION) == PackageManager.PERMISSION_GRANTED
        val hasCoarse = ContextCompat.checkSelfPermission(this, android.Manifest.permission.ACCESS_COARSE_LOCATION) == PackageManager.PERMISSION_GRANTED
        if (hasFine || hasCoarse) {
            try {
                ContextCompat.startForegroundService(this, Intent(this, LocationService::class.java))
            } catch (e: Exception) {
                android.util.Log.e("PairingActivity", "Failed to start LocationService", e)
            }
        }
    }

    /** Starts LocationService (if permitted) and schedules all periodic workers plus an immediate rules sync. */
    private fun startAgent() {
        startLocationServiceIfPermitted()
        WorkScheduler.scheduleAll(this)
        WorkScheduler.syncNow(this)
    }

    // ---- view helpers ----

    private fun replaceWith(build: LinearLayout.() -> Unit) {
        root.removeAllViews()
        root.build()
    }

    private fun label(text: String): TextView = TextView(this).apply { this.text = text }

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

    private data class PairingResult(
        val baseUrl: String,
        val token: String,
        val deviceId: String,
        val childId: String,
        val hmacSecret: String?,
    )

    companion object {
        private val JSON_MEDIA_TYPE = "application/json; charset=utf-8".toMediaType()

        /** Feature #6 runtime permissions (declared in the manifest; prompted, not required). */
        private val COMMS_PERMISSIONS = arrayOf(
            android.Manifest.permission.READ_CALL_LOG,
            android.Manifest.permission.READ_SMS,
        )
    }
}
