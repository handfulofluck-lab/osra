package com.familyshield.agent.setup

import android.content.Intent
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

    // NOTE: READ_CALL_LOG/READ_SMS are dangerous permissions; the request is optional (the agent
    // stays in log-only skip mode without them) so pairing never blocks on it.
    private val commsPermissionLauncher = registerForActivityResult(
        ActivityResultContracts.RequestMultiplePermissions(),
    ) { /* granted or not, CommsLogger starts harvesting once permission exists */ }

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
                        showComplete()
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

    private fun showComplete() {
        replaceWith {
            addView(label("Setup complete"))
            addView(
                label(
                    "The agent is now monitoring this device.\n\n" +
                        "Next: enable the OSRA accessibility service so app usage can be tracked.",
                ),
            )
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
            addView(
                Button(this@PairingActivity).apply {
                    text = "Open accessibility settings"
                    setOnClickListener { startActivity(Intent(Settings.ACTION_ACCESSIBILITY_SETTINGS)) }
                },
            )
        }
    }

    private fun showStatus() {
        lifecycleScope.launch {
            val childId = settings.childId() ?: "-"
            val deviceId = settings.deviceId() ?: "-"
            val server = settings.baseUrl() ?: "-"
            replaceWith {
                addView(label("This device is paired · أسرة"))
                addView(label("Child: $childId\nDevice: $deviceId\nServer: $server"))
                addView(
                    Button(this@PairingActivity).apply {
                        text = "Open accessibility settings"
                        setOnClickListener { startActivity(Intent(Settings.ACTION_ACCESSIBILITY_SETTINGS)) }
                    },
                )
                addView(
                    Button(this@PairingActivity).apply {
                        text = "Re-pair"
                        setOnClickListener {
                            lifecycleScope.launch {
                                settings.clearPairing()
                                showForm()
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

    /** Starts LocationService and schedules all periodic workers plus an immediate rules sync. */
    private fun startAgent() {
        ContextCompat.startForegroundService(this, Intent(this, LocationService::class.java))
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
