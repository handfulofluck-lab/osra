package com.familyshield.agent.security

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
class TamperGuardActivity : ComponentActivity() {

    @Inject lateinit var pinStore: ParentPinStore

    private var attempts = 0

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        window.addFlags(WindowManager.LayoutParams.FLAG_SECURE)
        val reason = intent.getStringExtra(EXTRA_REASON) ?: REASON_SETTINGS

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

    companion object {
        const val EXTRA_REASON = "reason"
        const val REASON_SETTINGS = "settings"
        const val REASON_REPAIR = "repair"
        const val REASON_REMOVE = "remove"
        const val REASON_RING = "ring"
        private const val MAX_ATTEMPTS = 5
    }
}
