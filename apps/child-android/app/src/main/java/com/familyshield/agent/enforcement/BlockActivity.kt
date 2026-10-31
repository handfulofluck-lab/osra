package com.familyshield.agent.enforcement

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.OnBackPressedCallback
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
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.key
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.core.content.ContextCompat
import androidx.core.view.WindowCompat
import com.familyshield.agent.data.AgentSettings
import com.familyshield.agent.network.ApiService
import com.familyshield.agent.network.DeviceUnlinker
import com.familyshield.agent.network.dto.AlertDto
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
 */
@AndroidEntryPoint
class BlockActivity : ComponentActivity() {

    @Inject lateinit var api: ApiService
    @Inject lateinit var settings: AgentSettings
    @Inject lateinit var appBlocker: AppBlocker

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

        setContent {
            MaterialTheme {
                Surface(modifier = Modifier.fillMaxSize(), color = Color(0xFF131318)) {
                    // Keyed on the package so the "Request sent" state belongs to one app, not to the
                    // instance: a second block starts with a fresh button.
                    key(request.packageId) {
                        BlockScreen(
                            appLabel = appLabel,
                            timeLimit = request.timeLimit,
                            onRequestAccess = { requestAccess(session.requestAccessPackage(), request.reason) },
                            onExit = { goHome() },
                        )
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
            if (intent?.action != DeviceUnlinker.ACTION_UNLINKED) return
            if (!settings.isPairedSync()) finish()
        }
    }

    override fun onStart() {
        super.onStart()
        ContextCompat.registerReceiver(
            this,
            unlinkedReceiver,
            IntentFilter(DeviceUnlinker.ACTION_UNLINKED),
            ContextCompat.RECEIVER_NOT_EXPORTED,
        )
    }

    override fun onStop() {
        runCatching { unregisterReceiver(unlinkedReceiver) }
        super.onStop()
    }

    override fun onResume() {
        super.onResume()
        // Issue #488: the unlink happened while this screen was in the background.
        if (!settings.isPairedSync()) finish()
    }

    /**
     * Issue #217: a second block reuses this `singleTask` instance. Without this override the screen kept
     * the first app's package, so "Request access" asked the parent to unblock the wrong app.
     */
    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        applyIntent(intent)
    }

    private fun applyIntent(intent: Intent) {
        session.apply(intent.getStringExtra(EXTRA_PACKAGE), intent.getStringExtra(EXTRA_REASON))
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

    /** POSTs an app_blocked alert for the blocked package; failures are swallowed (best effort). */
    private fun requestAccess(pkg: String, reason: String) {
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
                        metadata = mapOf("packageId" to pkg, "reason" to reason),
                    ),
                )
            }
        }
    }

    companion object {
        /** Intent extra: the package that was blocked. */
        const val EXTRA_PACKAGE: String = "package"

        /** Intent extra: block reason (REASON_BLOCKED or REASON_TIME_LIMIT). */
        const val EXTRA_REASON: String = "reason"

        /** Reason value: the app is blocked by a parent rule. */
        const val REASON_BLOCKED: String = "blocked"

        /** Reason value: the app's daily time limit is used up. */
        const val REASON_TIME_LIMIT: String = "time_limit"
    }
}

@Composable
private fun BlockScreen(
    appLabel: String,
    timeLimit: Boolean,
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
            text = if (timeLimit) "Daily limit reached" else "This app is blocked by your parent",
            style = MaterialTheme.typography.headlineMedium,
            color = Color.White,
            textAlign = TextAlign.Center,
        )
        Spacer(modifier = Modifier.height(16.dp))
        Text(text = appLabel, color = Color(0xFFAEB0B8), textAlign = TextAlign.Center)
        Spacer(modifier = Modifier.height(40.dp))
        if (sent) {
            Text(text = "Request sent to your parent", color = Color(0xFF9CCC65))
        } else {
            Button(onClick = {
                onRequestAccess()
                sent = true
            }) {
                Text("Request access")
            }
        }
        Spacer(modifier = Modifier.height(16.dp))
        TextButton(onClick = onExit) {
            Text("Exit to Home screen", color = Color.White)
        }
    }
}
