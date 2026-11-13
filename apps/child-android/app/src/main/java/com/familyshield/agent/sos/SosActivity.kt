package com.familyshield.agent.sos

import android.content.Intent
import android.content.pm.PackageManager
import android.Manifest
import android.os.Build
import android.os.Bundle
import android.os.SystemClock
import android.util.Log
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.safeDrawing
import androidx.compose.foundation.layout.windowInsetsPadding
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.core.content.ContextCompat
import com.familyshield.agent.data.AgentSettings
import com.familyshield.agent.network.ApiService
import com.familyshield.agent.network.dto.AlertDto
import com.familyshield.agent.services.LocationService
import com.google.android.gms.location.LocationServices
import dagger.hilt.android.AndroidEntryPoint
import javax.inject.Inject
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlinx.coroutines.withTimeoutOrNull

/**
 * Feature #14 child SOS, full-screen: a big SOS button starts a 5 s cancelable countdown
 * (pocket-dial guard, pure [SosStateMachine]); at zero it HMAC-POSTs a critical sos alert to
 * /v1/alerts/internal and shows "Alert sent — stay where you are". The parent-side sos_clear
 * command dismisses this screen via EXTRA_DISMISS (single-task onNewIntent).
 * // NOTE: placing a real call/SMS to the parent's phone number is a placeholder — delivery is
 * the alert pipeline (parent app push), matching the server-side sos category contract.
 */
@AndroidEntryPoint
class SosActivity : ComponentActivity() {

    @Inject lateinit var api: ApiService
    @Inject lateinit var settings: AgentSettings

    private val machine = SosStateMachine()
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)

    /** Issue #672: the platform's own last fix, the same source `locate_now` falls back to. */
    private val fused by lazy { LocationServices.getFusedLocationProviderClient(this) }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        @Suppress("DEPRECATION")
        window.addFlags(
            android.view.WindowManager.LayoutParams.FLAG_SHOW_WHEN_LOCKED or
                android.view.WindowManager.LayoutParams.FLAG_TURN_SCREEN_ON,
        )
        applyIntent(intent)
        setContent {
            MaterialTheme {
                Surface(modifier = Modifier.fillMaxSize(), color = Color(0xFF131318)) {
                    SosScreen(
                        machine = machine,
                        onFired = ::sendSos,
                        onClose = { finish() },
                    )
                }
            }
        }
    }

    override fun onNewIntent(intent: android.content.Intent) {
        super.onNewIntent(intent)
        applyIntent(intent)
    }

    /** sos_clear lands here (single-task) and tears the screen down. */
    private fun applyIntent(intent: android.content.Intent) {
        if (intent.getBooleanExtra(EXTRA_DISMISS, false)) finish()
    }

    /** Fire-and-forget critical sos alert, with the phone's last known fix; failures swallowed. */
    private fun sendSos() {
        val sentAtMs = System.currentTimeMillis()
        scope.launch {
            // Issue #672: the parent needs "where" in the same breath as the SOS. The fix is waited for at
            // most [LAST_FIX_WAIT_MS] — a phone that cannot say where it is must still send the SOS, and the
            // 10 s budget from the tap does not survive a longer wait.
            val fix = lastKnownFix()
            runCatching {
                val deviceId = settings.deviceId()
                api.postInternalAlert(
                    AlertDto(
                        childId = settings.childId(),
                        deviceId = deviceId,
                        severity = "critical",
                        category = "sos",
                        title = "SOS from ${Build.MODEL}",
                        body = "Your child pressed the SOS button",
                        // Issue #672: the five location keys join the id, and are simply absent when the
                        // phone has no fix — an SOS without a place is still an SOS.
                        metadata = mapOf("deviceId" to (deviceId ?: "")) +
                            SosLocationPolicy.metadata(fix, sentAtMs),
                    ),
                )
            }
        }
        requestFreshFix()
    }

    /**
     * Issue #672: the platform's last known fix, the same source `locate_now` falls back to, bounded so the
     * alert is never held up by a location task that does not answer.
     */
    private suspend fun lastKnownFix(): SosLocationPolicy.Fix? = try {
        withTimeoutOrNull(LAST_FIX_WAIT_MS) {
            suspendCancellableCoroutine { cont ->
                try {
                    fused.lastLocation
                        .addOnSuccessListener { location ->
                            if (!cont.isActive) return@addOnSuccessListener
                            cont.resume(
                                location?.let {
                                    SosLocationPolicy.Fix(it.latitude, it.longitude, it.accuracy, it.time)
                                },
                            ) {}
                        }
                        .addOnFailureListener { if (cont.isActive) cont.resume(null) {} }
                } catch (e: SecurityException) {
                    if (cont.isActive) cont.resume(null) {}
                }
            }
        }
    } catch (e: Exception) {
        null
    }

    /**
     * Issue #672: a fresh high-accuracy fix as a follow-up ping, the `locate_now` path without a command —
     * [LocationService] takes one fix and flushes it at once, so the parent's map moves seconds after the
     * alert rather than at the next batch.
     *
     * Started from this resumed activity, so the while-in-use grant is enough and `ACCESS_BACKGROUND_LOCATION`
     * is not a precondition (`LocationServiceStartSitesTest`'s foreground list says the same). No
     * `LocationStartPolicy` gate: this is not a background start. [SosFreshFixPolicy] is the narrower rule
     * that still applies — an unpaired phone has nobody to show the ping to (#672 review, Fable note 1).
     */
    private fun requestFreshFix() {
        if (!SosFreshFixPolicy.shouldRequest(settings.isPairedSync(), hasLocationPermission())) return
        runCatching {
            ContextCompat.startForegroundService(
                this,
                Intent(this, LocationService::class.java).setAction(LocationService.ACTION_PING_NOW),
            )
        }.onFailure { Log.w(TAG, "SOS: the OS refused the location service start", it) }
    }

    private fun hasLocationPermission(): Boolean =
        ContextCompat.checkSelfPermission(this, Manifest.permission.ACCESS_FINE_LOCATION) ==
            PackageManager.PERMISSION_GRANTED ||
            ContextCompat.checkSelfPermission(this, Manifest.permission.ACCESS_COARSE_LOCATION) ==
            PackageManager.PERMISSION_GRANTED

    companion object {
        /** Intent extra: dismiss the SOS screen (parent-side sos_clear command). */
        const val EXTRA_DISMISS: String = "dismiss"

        private const val TAG = "SosActivity"

        /** #672: how long the alert waits for the platform's last fix before going without one. */
        internal const val LAST_FIX_WAIT_MS: Long = 1_500L
    }
}

@Composable
private fun SosScreen(
    machine: SosStateMachine,
    onFired: () -> Unit,
    onClose: () -> Unit,
) {
    var state by remember { mutableStateOf(machine.state) }
    var alertDispatched by remember { mutableStateOf(false) }

    // Countdown ticker: re-keyed on every Counting snapshot, ~10 Hz.
    if (state is SosStateMachine.State.Counting) {
        LaunchedEffect(state) {
            delay(100)
            state = machine.tick(SystemClock.elapsedRealtime())
        }
    }
    // Fire exactly once when the machine hits Fired.
    if (state is SosStateMachine.State.Fired && !alertDispatched) {
        alertDispatched = true
        LaunchedEffect(Unit) { onFired() }
    }

    // #489: drawn edge to edge at targetSdk 35; keep the content clear of the status bar and the cutout.
    Column(
        modifier = Modifier.fillMaxSize().windowInsetsPadding(WindowInsets.safeDrawing).padding(32.dp),
        verticalArrangement = Arrangement.Center,
        horizontalAlignment = Alignment.CenterHorizontally,
    ) {
        when (val s = state) {
            is SosStateMachine.State.Counting -> {
                Text(
                    text = "Sending SOS in ${(s.remainingMs + 999) / 1000}…",
                    style = MaterialTheme.typography.headlineMedium,
                    color = Color.White,
                    textAlign = TextAlign.Center,
                )
                Spacer(modifier = Modifier.height(16.dp))
                Text(
                    text = "Stay calm — tap Cancel if this was accidental.",
                    color = Color(0xFFAEB0B8),
                    textAlign = TextAlign.Center,
                )
                Spacer(modifier = Modifier.height(40.dp))
                TextButton(onClick = { state = machine.cancel() }) {
                    Text("Cancel", color = Color.White)
                }
            }
            SosStateMachine.State.Fired -> {
                Text(
                    text = "Alert sent — stay where you are",
                    style = MaterialTheme.typography.headlineMedium,
                    color = Color(0xFFEF9A9A),
                    textAlign = TextAlign.Center,
                )
                Spacer(modifier = Modifier.height(16.dp))
                Text(
                    text = "Your parent has been notified.",
                    color = Color(0xFFAEB0B8),
                    textAlign = TextAlign.Center,
                )
            }
            else -> {
                Text(
                    text = "Need help right now?",
                    style = MaterialTheme.typography.headlineMedium,
                    color = Color.White,
                    textAlign = TextAlign.Center,
                )
                Spacer(modifier = Modifier.height(40.dp))
                Button(
                    onClick = { state = machine.start(SystemClock.elapsedRealtime()) },
                    colors = ButtonDefaults.buttonColors(containerColor = Color(0xFFD32F2F)),
                ) {
                    Text("SOS", style = MaterialTheme.typography.displaySmall)
                }
                if (s == SosStateMachine.State.Cancelled) {
                    Spacer(modifier = Modifier.height(16.dp))
                    Text(text = "SOS cancelled.", color = Color(0xFFAEB0B8))
                }
                Spacer(modifier = Modifier.height(40.dp))
                TextButton(onClick = onClose) {
                    Text("Close", color = Color.White)
                }
            }
        }
    }
}
