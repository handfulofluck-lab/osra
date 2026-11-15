package com.familyshield.agent.commands

import android.app.Activity
import android.content.Intent
import android.os.Build
import android.os.Bundle
import android.view.Gravity
import android.view.KeyEvent
import android.view.WindowManager
import android.widget.Button
import android.widget.LinearLayout
import android.widget.TextView
import com.familyshield.agent.R
import com.familyshield.agent.security.TamperGuardActivity

/**
 * Plan 1.7 — the full-screen "your parent is ringing this phone" screen: shown over the lock screen,
 * turns the screen on, keeps it on, and offers exactly one way out — the parent PIN (via the tamper
 * guard). Back and the volume keys are swallowed ([RingPolicy]); the parent's `stop_ring` /
 * `sos_clear` dismisses it through [EXTRA_DISMISS]. Single-task so a second ring re-delivers here.
 */
class RingActivity : Activity() {

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        if (intent.getBooleanExtra(EXTRA_DISMISS, false)) { finish(); return }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O_MR1) { setShowWhenLocked(true); setTurnScreenOn(true) }
        window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON or WindowManager.LayoutParams.FLAG_SECURE)
        setContentView(
            LinearLayout(this).apply {
                orientation = LinearLayout.VERTICAL
                gravity = Gravity.CENTER
                val pad = (24 * resources.displayMetrics.density).toInt()
                setPadding(pad, pad, pad, pad)
                setBackgroundColor(0xFFB00020.toInt())
                addView(
                    TextView(context).apply {
                        text = getString(R.string.ring_title)
                        textSize = 24f
                        setTextColor(0xFFFFFFFF.toInt())
                        gravity = Gravity.CENTER
                    },
                )
                addView(
                    TextView(context).apply {
                        text = "\n" + getString(R.string.ring_body)
                        textSize = 16f
                        setTextColor(0xFFFFFFFF.toInt())
                        gravity = Gravity.CENTER
                    },
                )
                addView(
                    Button(context).apply {
                        text = getString(R.string.ring_stop)
                        setOnClickListener {
                            startActivityForResult(
                                Intent(this@RingActivity, TamperGuardActivity::class.java).putExtra(TamperGuardActivity.EXTRA_REASON, TamperGuardActivity.REASON_RING),
                                REQ_PIN,
                            )
                        }
                    },
                )
            },
        )
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        if (intent.getBooleanExtra(EXTRA_DISMISS, false)) finish()
    }

    override fun onResume() {
        super.onResume()
        if (!Ringer.isRinging) finish()
    }

    @Deprecated("Deprecated in Java")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode == REQ_PIN && resultCode == RESULT_OK) {
            Ringer.stop(this, RingPolicy.StopSource.PIN_VERIFIED)
            finish()
        }
    }

    /** Back and the volume keys do nothing — the child cannot silence a ring (RingPolicy). */
    override fun onKeyDown(keyCode: Int, event: KeyEvent?): Boolean = when (keyCode) {
        KeyEvent.KEYCODE_BACK, KeyEvent.KEYCODE_VOLUME_DOWN, KeyEvent.KEYCODE_VOLUME_UP, KeyEvent.KEYCODE_VOLUME_MUTE -> true
        else -> super.onKeyDown(keyCode, event)
    }

    @Deprecated("Deprecated in Java")
    override fun onBackPressed() { /* RingPolicy.CHILD_BACK: not a stop path */ }

    companion object {
        const val EXTRA_DISMISS = "dismiss"
        private const val REQ_PIN = 71
    }
}
