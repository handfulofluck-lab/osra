package com.familyshield.agent.commands

import android.app.KeyguardManager
import android.content.Intent
import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.OnBackPressedCallback
import androidx.activity.compose.setContent
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import com.familyshield.agent.enforcement.KeyguardPolicy

/**
 * Full-screen overlay used by CommandDispatcher. MODE_LOCKED shows "device locked by your
 * parent" (fallback when the app is not device owner); MODE_PAUSED shows the paused-device
 * messaging; MODE_PAUSED_INTERNET shows the pause-internet messaging (Feature #11);
 * MODE_UNLOCK requests keyguard dismissal and finishes; MODE_DISMISS just finishes (used by
 * resume_internet to tear the paused-internet overlay down). Single-task: repeat commands
 * re-deliver via onNewIntent and re-apply, so resume/pause always lands on the visible overlay.
 * Cannot be dismissed with Back or Home (AND-05): back is swallowed and navigation away re-raises.
 */
class LockActivity : ComponentActivity() {

    @Volatile private var currentMode: String = MODE_LOCKED

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        @Suppress("DEPRECATION")
        // Issue #87: FLAG_SHOW_WHEN_LOCKED is deliberately NOT set. Drawing over the keyguard put this
        // activity in front of the bouncer and locked the owner out of their own PIN (2026-10-17, handset).
        // The overlay defers to the keyguard instead — see applyMode and KeyguardPolicy.
        window.addFlags(android.view.WindowManager.LayoutParams.FLAG_TURN_SCREEN_ON)
        onBackPressedDispatcher.addCallback(this, object : OnBackPressedCallback(true) {
            override fun handleOnBackPressed() {
                // Intercept and swallow back press: lock/pause overlay cannot be dismissed by child (AND-05)
            }
        })
        applyMode(intent)
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        applyMode(intent)
    }

    override fun onUserLeaveHint() {
        super.onUserLeaveHint()
        // Deliberately does NOT re-raise. See onPause.
    }

    override fun onPause() {
        super.onPause()
        // The overlay is re-raised by AccessibilityMonitorService for every NON-EXEMPT foreground
        // window (LockEnforcementPolicy.shouldReraise, debounced), not by this activity. That split
        // matters: an unconditional self-re-raise here runs on the way out — before the next window
        // is known — so it also ran when the next window was the emergency dialer, and the overlay
        // took the front back after the child had opened it (found on the handset 2026-10-17: with
        // the exemption in place, S1 still read LockActivity on top at 2/6/11 s, and the control run
        // with the overlay down showed the dialer's task had been created but never resumed).
        // Cost of the split: with the accessibility service off there is no self-re-raise, and that
        // service is already a hard requirement for blocking and the tamper guard (status screen:
        // "nothing works without it").
    }

    private fun applyMode(intent: Intent) {
        val mode = intent.getStringExtra(EXTRA_MODE) ?: MODE_LOCKED
        // Issue #87: never draw over the keyguard. The bouncer must stay reachable so the owner can
        // enter their PIN; LockState keeps the mode and AccessibilityMonitorService re-raises the
        // overlay over the first non-exempt window after the keyguard is gone.
        val keyguardLocked = getSystemService(KeyguardManager::class.java)?.isKeyguardLocked == true
        if (KeyguardPolicy.shouldDeferToKeyguard(mode, keyguardLocked)) {
            currentMode = mode
            finish()
            return
        }
        when (mode) {
            MODE_UNLOCK -> {
                currentMode = MODE_UNLOCK
                val km = getSystemService(KeyguardManager::class.java)
                km.requestDismissKeyguard(this, null)
                finish()
            }
            MODE_DISMISS -> {
                currentMode = MODE_DISMISS
                finish()
            }
            else -> {
                currentMode = mode
                setContent {
                    MaterialTheme {
                        Surface(modifier = Modifier.fillMaxSize(), color = Color(0xFF131318)) {
                            OverlayScreen(mode)
                        }
                    }
                }
            }
        }
    }

    companion object {
        /** Intent extra selecting the mode (MODE_LOCKED, MODE_PAUSED, MODE_PAUSED_INTERNET, MODE_UNLOCK or MODE_DISMISS). */
        const val EXTRA_MODE: String = "mode"

        /** Shows the lock overlay. */
        const val MODE_LOCKED: String = "locked"

        /** Shows the paused overlay (same mechanics, paused messaging). */
        const val MODE_PAUSED: String = "paused"

        /** Shows the pause-internet overlay (Feature #11); stays up until resume_internet dismisses it. */
        const val MODE_PAUSED_INTERNET: String = "paused_internet"

        /** Dismisses the keyguard and finishes. */
        const val MODE_UNLOCK: String = "unlock"

        /** Finishes the visible overlay without touching the keyguard (resume_internet). */
        const val MODE_DISMISS: String = "dismiss"
    }
}

@Composable
private fun OverlayScreen(mode: String) {
    val (title, subtitle) = when (mode) {
        LockActivity.MODE_PAUSED -> "Device paused by your parent" to "Your parent will resume it shortly. · أسرة"
        LockActivity.MODE_PAUSED_INTERNET ->
            "Internet paused by your parent" to "Educational apps still work. · أسرة"
        else -> "This device is locked by your parent" to "It will unlock when your parent allows it. · أسرة"
    }
    Column(
        modifier = Modifier.fillMaxSize().padding(32.dp),
        verticalArrangement = Arrangement.Center,
        horizontalAlignment = Alignment.CenterHorizontally,
    ) {
        Text(
            text = title,
            style = MaterialTheme.typography.headlineMedium,
            color = Color.White,
            textAlign = TextAlign.Center,
        )
        Spacer(modifier = Modifier.height(16.dp))
        Text(
            text = subtitle,
            color = Color(0xFFAEB0B8),
            textAlign = TextAlign.Center,
        )
    }
}
