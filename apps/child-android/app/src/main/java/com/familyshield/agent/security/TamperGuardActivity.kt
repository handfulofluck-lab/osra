package com.familyshield.agent.security

import android.content.res.Configuration
import android.os.Bundle
import android.text.InputFilter
import android.text.InputType
import android.view.Gravity
import android.view.WindowManager
import android.widget.Button
import android.widget.EditText
import android.widget.LinearLayout
import android.widget.TextView
import androidx.activity.ComponentActivity
import dagger.hilt.android.AndroidEntryPoint
import javax.inject.Inject

/**
 * Full-screen parent-PIN gate (ADR-0010 §3). Launched by the accessibility service over the OS
 * screens that remove protection (deactivate admin, uninstall, app info) and by the in-app
 * "Re-pair" / "Remove protection" actions. A correct PIN grants a [TamperScreenPolicy.GRACE_MS]
 * window during which the guard stands down so the parent can finish what they opened; anything
 * else sends the child back to the launcher.
 *
 * Deliberately plain views (no Compose) and no network: it must come up instantly on a low-end
 * phone and work with the agent's data cleared of everything but the secure store.
 */
@AndroidEntryPoint
open class TamperGuardActivity : ComponentActivity() {

    @Inject lateinit var pinStore: ParentPinStore

    private var attempts = 0

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        window.addFlags(WindowManager.LayoutParams.FLAG_SECURE)
        val reason = intent.getStringExtra(EXTRA_REASON) ?: REASON_SETTINGS
        // Plan 1.7 (found on the Flip4, TR-17): the ring screen sits over the lock screen, so the PIN gate it
        // opens must too — otherwise the keyguard comes up instead and the parent cannot stop the ring.
        if (reason == REASON_RING && android.os.Build.VERSION.SDK_INT >= android.os.Build.VERSION_CODES.O_MR1) {
            setShowWhenLocked(true)
            setTurnScreenOn(true)
        }

        val pin = EditText(this).apply {
            hint = "Parent PIN"
            inputType = InputType.TYPE_CLASS_NUMBER or InputType.TYPE_NUMBER_VARIATION_PASSWORD
            filters = arrayOf(InputFilter.LengthFilter(ParentPin.MAX_LENGTH))
            textSize = 24f
            gravity = Gravity.CENTER
        }
        val error = TextView(this).apply { setTextColor(0xFFB00020.toInt()); textSize = 16f }
        val unlock = Button(this).apply { text = "Continue" }
        val back = Button(this).apply { text = "Go back" }

        // osra-security#17: Continue stays disabled until the field holds a length the PIN can have, so
        // an empty submit never reaches the verifier at all. The verifier fails closed on its own now;
        // this is the other half — a button that cannot be pressed with nothing typed.
        //
        // Two silences here are deliberate, both decided by the UI/UX Bureau on #761 and both worth
        // keeping rather than "improving":
        //  - **no explanatory line** under a disabled button. Every phone's own passcode screen behaves
        //    this way, a parent reads a greyed Continue beside an empty field correctly, and extra words
        //    on this particular screen are read mostly by the child.
        //  - **no printed 4–8 digit rule**. Printing it here tells the person who is not meant to pass
        //    this gate what shape the secret has; the rule belongs where the PIN is set, and it is there.
        //
        // There is also no IME submit path: the field sets `inputType` and a length filter and nothing
        // else, so the keyboard's Done only hides the keyboard and the button is the only way in.
        fun syncUnlockEnabled() {
            unlock.isEnabled =
                pin.text.length in ParentPin.MIN_LENGTH..ParentPin.MAX_LENGTH
        }
        pin.addTextChangedListener(object : android.text.TextWatcher {
            override fun beforeTextChanged(s: CharSequence?, start: Int, count: Int, after: Int) = Unit
            override fun onTextChanged(s: CharSequence?, start: Int, before: Int, count: Int) =
                syncUnlockEnabled()

            override fun afterTextChanged(s: android.text.Editable?) = Unit
        })
        syncUnlockEnabled()

        unlock.setOnClickListener {
            val entered = pin.text.toString()
            if (pinStore.verify(entered)) {
                TamperState.grantGrace(this, System.currentTimeMillis() + TamperScreenPolicy.GRACE_MS)
                setResult(RESULT_OK)
                finish()
            } else {
                attempts += 1
                pin.text.clear()
                error.text = if (attempts >= MAX_ATTEMPTS) {
                    "Too many attempts. Ask your parent."
                } else {
                    "Wrong PIN."
                }
                if (attempts >= MAX_ATTEMPTS) goHome()
            }
        }
        back.setOnClickListener { goHome() }

        setContentView(
            LinearLayout(this).apply {
                orientation = LinearLayout.VERTICAL
                gravity = Gravity.CENTER
                setBackgroundColor(0xFF0D1B2A.toInt())
                setPadding(64, 64, 64, 64)
                addView(
                    TextView(this@TamperGuardActivity).apply {
                        text = "Protected by OSRA · أسرة"
                        setTextColor(0xFFFFFFFF.toInt())
                        textSize = 26f
                        gravity = Gravity.CENTER
                    },
                )
                addView(
                    TextView(this@TamperGuardActivity).apply {
                        text = when (reason) {
                            REASON_REPAIR -> "Re-pairing this device needs your parent's PIN."
                            REASON_REMOVE -> "Removing protection needs your parent's PIN."
                            REASON_RING -> "Stopping the ring needs your parent's PIN."
                            else -> "Changing this setting needs your parent's PIN.\nYour parent has been notified."
                        }
                        setTextColor(0xFFAEB0B8.toInt())
                        textSize = 16f
                        gravity = Gravity.CENTER
                        setPadding(0, 24, 0, 40)
                    },
                )
                addView(pin)
                addView(error)
                addView(unlock)
                addView(back)
            },
        )
    }

    // #533 review: the guard's debounce reads these — it may skip a protection screen only while the gate is in
    // front. onPause completes before the next activity resumes, so a screen that comes back over a paused gate
    // is always judged.
    override fun onResume() {
        super.onResume()
        GuardGateState.lastResumedMs = System.currentTimeMillis()
        GuardGateState.showing = true
        onSharingChanged(isInMultiWindowMode)
    }

    override fun onPause() {
        GuardGateState.showing = false
        GuardGateState.multiWindow = false
        super.onPause()
    }

    override fun onMultiWindowModeChanged(isInMultiWindowMode: Boolean, newConfig: Configuration) {
        super.onMultiWindowModeChanged(isInMultiWindowMode, newConfig)
        onSharingChanged(isInMultiWindowMode)
    }

    /** Hardware back is the same as "Go back": never a way through. */
    @Deprecated("Deprecated in Java")
    override fun onBackPressed() {
        goHome()
    }

    private fun goHome() {
        setResult(RESULT_CANCELED)
        startActivity(
            android.content.Intent(android.content.Intent.ACTION_MAIN)
                .addCategory(android.content.Intent.CATEGORY_HOME)
                .addFlags(android.content.Intent.FLAG_ACTIVITY_NEW_TASK),
        )
        finish()
    }

    /**
     * osra-security#7: true only for the gate the accessibility guard opens. An in-app gate protects an action
     * that runs only after the PIN, so sharing the screen exposes nothing there, and refusing would lose the
     * result its caller waits for.
     */
    protected open val guardGate: Boolean = false

    /**
     * osra-security#7: the guard's gate sharing the screen covers nothing (the protection screen stays usable in
     * the other half). It is already alone in a non-resizeable task, so relaunching cannot help: it goes Home.
     * Any gate sets the flag, which tells the guard to judge every protection screen again meanwhile.
     */
    private fun onSharingChanged(inMultiWindow: Boolean) {
        GuardGateState.multiWindow = inMultiWindow
        if (GuardMultiWindowPolicy.goHome(guardGate, inMultiWindow)) goHome()
    }

    companion object {
        const val EXTRA_REASON = "reason"
        const val REASON_SETTINGS = "settings"
        const val REASON_REPAIR = "repair"
        const val REASON_REMOVE = "remove"
        const val REASON_RING = "ring"
        private const val MAX_ATTEMPTS = 5
    }
}

/**
 * osra-security#7: the gate the accessibility guard opens. Same screen as [TamperGuardActivity], declared with
 * its own task affinity, so it is the root of a task that is not resizeable. In OSRA's own task (the old
 * launch), the task's root was the status screen, which is resizeable, so Recents offered split screen for it;
 * and a correct PIN finished the gate into that status screen instead of the screen the parent had opened.
 * In-app callers keep [TamperGuardActivity]: they wait for its result, which a separate task cannot return.
 */
class TamperGuardTaskActivity : TamperGuardActivity() {
    override val guardGate: Boolean = true
}
