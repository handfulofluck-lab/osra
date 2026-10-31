package com.familyshield.agent.commands

import android.app.KeyguardManager
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
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.core.content.ContextCompat
import com.familyshield.agent.enforcement.KeyguardPolicy
import com.familyshield.agent.enforcement.LockScreenPolicy
import com.familyshield.agent.enforcement.LockState
import com.familyshield.agent.network.DeviceUnlinker

/**
 * Full-screen overlay used by CommandDispatcher. MODE_LOCKED shows "device locked by your
 * parent" (fallback when the app is not device owner); MODE_PAUSED shows the paused-device
 * messaging; MODE_PAUSED_INTERNET shows the pause-internet messaging (Feature #11);
 * MODE_UNLOCK requests keyguard dismissal and finishes; MODE_DISMISS just finishes (used by
 * resume_internet to tear the paused-internet overlay down). Single-task: repeat commands
 * re-deliver via onNewIntent and re-apply, so resume/pause always lands on the visible overlay.
 * Cannot be dismissed with Back or Home (AND-05): back is swallowed and navigation away re-raises.
 *
 * Issue #233 review (F2): the intent is only a wake-up — what is drawn comes from [LockState],
 * through [LockScreenPolicy], so a replayed MODE_UNLOCK cannot finish a lock a later `lock` raised.
 */
class LockActivity : ComponentActivity() {

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

    /**
     * Issue #488: an overlay left open across an unlink kept saying the device was locked. The unlink
     * clears [LockState] before it announces itself, so the receiver re-reads it rather than trusting the
     * broadcast. The background path needs nothing new: [onResume] already finishes when [LockState]
     * no longer holds a locking mode.
     */
    private val unlinkedReceiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context?, intent: Intent?) {
            if (intent?.action != DeviceUnlinker.ACTION_UNLINKED) return
            if (!LockState.isActive(this@LockActivity)) finish()
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
        // Issue #233 review (F1): our own visible window is what lets Android start this activity
        // from the background (BAL_ALLOW_VISIBLE_WINDOW), so CommandDispatcher checks this flag
        // before launching an unlock. Cleared in onStop: an activity that is no longer visible is
        // nothing an unlock can take down, and a blind launch would only recreate the blocked
        // activity record F2 describes.
        onStartedVisible()
    }

    override fun onStop() {
        runCatching { unregisterReceiver(unlinkedReceiver) }
        super.onStop()
        onStoppedVisible()
    }

    override fun onResume() {
        super.onResume()
        // Issue #233 review (F2): an instance restored from Recents may still be drawing a mode the
        // parent already cleared (unlock, or resume_internet's dismiss). LockState is the truth, so a
        // stale instance finishes instead of re-asserting a restriction that is no longer stored.
        val decision = LockScreenPolicy.resolve(LockState.mode(this), intent.getStringExtra(EXTRA_MODE))
        if (decision !is LockScreenPolicy.Decision.Show) finish()
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
        // Issue #233 review (F2): the intent is a wake-up, LockState is the truth. Drawing from the
        // intent let a replayed MODE_UNLOCK — queued on an activity record a refused `lock` created
        // and never started — finish a lock screen a later `lock` had just raised (measured on the
        // Flip4, 2026-10-20: 5 ms after on_create, with the `lock` ack saying via=overlay).
        when (val decision = LockScreenPolicy.resolve(LockState.mode(this), intent.getStringExtra(EXTRA_MODE))) {
            is LockScreenPolicy.Decision.Show -> {
                // Issue #87: never draw over the keyguard. The bouncer must stay reachable so the
                // owner can enter their PIN; LockState keeps the mode and AccessibilityMonitorService
                // re-raises the overlay over the first non-exempt window after the keyguard is gone.
                val keyguardLocked = getSystemService(KeyguardManager::class.java)?.isKeyguardLocked == true
                if (KeyguardPolicy.shouldDeferToKeyguard(decision.mode, keyguardLocked)) {
                    finish()
                    return
                }
                setContent {
                    MaterialTheme {
                        Surface(modifier = Modifier.fillMaxSize(), color = Color(0xFF131318)) {
                            OverlayScreen(decision.mode)
                        }
                    }
                }
            }
            // Stored state says nothing of ours is up. The intent only decides whether the keyguard
            // our own lockNow() may have raised is dismissed on the way out.
            LockScreenPolicy.Decision.DismissKeyguard -> {
                getSystemService(KeyguardManager::class.java)?.requestDismissKeyguard(this, null)
                finish()
            }
            LockScreenPolicy.Decision.Finish -> finish()
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

        /**
         * Counts visible instances, and derives [isShowing] from it (issue #241).
         *
         * A single boolean was wrong: if a visible instance finishes and a new one starts before the
         * old one's `onStop`, the old `onStop` clears the flag while the new screen is up — a later
         * `unlock` would then ack `not_showing` and leave that screen in place. The count cannot be
         * misread that way.
         *
         * Process-scoped on purpose: it survives a configuration change (the instance stays started)
         * and resets on process death, which is the right default — after a restart nothing of ours
         * is on screen until a command or the accessibility service raises it again.
         */
        private val visible = VisibleScreens()

        /** True while at least one instance of this activity is visible. */
        val isShowing: Boolean
            get() = visible.isShowing

        internal fun onStartedVisible() = visible.started()

        internal fun onStoppedVisible() = visible.stopped()
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
    // #489: at targetSdk 35 the screen is drawn edge to edge, so in landscape the title sat under the
    // status bar and the cutout. The root keeps its 32 dp and adds whatever the system bars take.
    Column(
        modifier = Modifier.fillMaxSize().windowInsetsPadding(WindowInsets.safeDrawing).padding(32.dp),
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
