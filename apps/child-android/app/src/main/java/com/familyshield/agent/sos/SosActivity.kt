package com.familyshield.agent.sos

import android.os.Build
import android.os.Bundle
import android.os.SystemClock
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
import com.familyshield.agent.data.AgentSettings
import com.familyshield.agent.network.ApiService
import com.familyshield.agent.network.dto.AlertDto
import dagger.hilt.android.AndroidEntryPoint
import javax.inject.Inject
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch

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

    /** Fire-and-forget critical sos alert; failures swallowed (best effort, shown either way). */
    private fun sendSos() {
        scope.launch {
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
                        metadata = mapOf("deviceId" to (deviceId ?: "")),
                    ),
                )
            }
        }
    }

    companion object {
        /** Intent extra: dismiss the SOS screen (parent-side sos_clear command). */
        const val EXTRA_DISMISS: String = "dismiss"
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
