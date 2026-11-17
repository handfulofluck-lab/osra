package com.familyshield.agent.security

import android.content.res.Configuration
import android.os.Bundle
import android.os.SystemClock
import android.provider.Settings
import android.text.InputFilter
import android.text.InputType
import android.view.Gravity
import android.view.WindowManager
import android.widget.Button
import android.widget.EditText
import android.widget.LinearLayout
import android.widget.TextView
import androidx.activity.ComponentActivity
import com.familyshield.agent.R
import dagger.hilt.android.AndroidEntryPoint
import javax.inject.Inject

/**
 * osra-security#24: the gate's five-try rule, kept as the local name the wiring test reads.
 */
private const val MAX_ATTEMPTS = PinLockout.MAX_ATTEMPTS

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

    /** osra-security#24: the wrong-PIN count is persisted, so reopening this screen does not reset it. */
    @Inject lateinit var attemptStore: PinAttemptStore

    /** The banner under the field; a field so [refreshLockoutUi] can refresh it on a `singleTask` re-entry. */
    private lateinit var errorView: TextView

    /** [syncUnlockEnabled] is local to `onCreate`; [refreshLockoutUi] calls it through this on resume. */
    private var syncUnlockEnabledRef: (() -> Unit)? = null

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
            hint = getString(R.string.pin_gate_hint)
            inputType = InputType.TYPE_CLASS_NUMBER or InputType.TYPE_NUMBER_VARIATION_PASSWORD
            filters = arrayOf(InputFilter.LengthFilter(ParentPin.MAX_LENGTH))
            textSize = 24f
            gravity = Gravity.CENTER
        }
        // Codex on #792: `0xFFB00020` on this screen's `0xFF0D1B2A` measures 2.37:1, below the 4.5:1 the
        // Bureau holds normal text to. `0xFFFFB4AB` is the Material dark-theme error role and measures
        // 10.24:1 on the same background, so the banner is legible without changing a word of it. If the
        // Bureau names a different token, this one constant is the only thing that moves.
        errorView = TextView(this).apply { setTextColor(GuardPalette.ERROR_TEXT); textSize = 16f }
        val unlock = Button(this).apply { text = getString(R.string.pin_gate_continue) }
        val back = Button(this).apply { text = getString(R.string.pin_gate_back) }

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
            // #792 (Antigravity S1): the length was the only condition, so typing four digits re-enabled
            // Continue during a lockout — the tap was still refused, but the button contradicted the notice.
            val longEnough = pin.text.length in ParentPin.MIN_LENGTH..ParentPin.MAX_LENGTH
            unlock.isEnabled = longEnough && !PinLockout.isLocked(lockedState(), SystemClock.elapsedRealtime())
        }
        pin.addTextChangedListener(object : android.text.TextWatcher {
            override fun beforeTextChanged(s: CharSequence?, start: Int, count: Int, after: Int) = Unit
            override fun onTextChanged(s: CharSequence?, start: Int, before: Int, count: Int) =
                syncUnlockEnabled()

            override fun afterTextChanged(s: android.text.Editable?) = Unit
        })
        syncUnlockEnabled()
        syncUnlockEnabledRef = { syncUnlockEnabled() }

        // osra-security#24: reopening the screen must not hand back a fresh set of tries. The notice is
        // shown immediately, and Continue stays off for as long as the lockout lasts.
        //
        // Two clocks, and only one of them decides: a window is measured on `elapsedRealtime`, which a
        // changed wall clock cannot move. A reboot restarts it, so `anchored` re-anchors the window to a full
        // one from this read — a reboot costs a window, never more than one.
        if (PinLockout.isLocked(lockedState(), SystemClock.elapsedRealtime())) {
            errorView.text = noticeText()
            unlock.isEnabled = false
        }

        unlock.setOnClickListener {
            // The wall clock is only ever handed to the grace window and the alert; nothing here compares it.
            val now = System.currentTimeMillis()
            val elapsed = SystemClock.elapsedRealtime()
            // osra-security#24: a closed gate refuses **every** PIN, the right one included. Checking this
            // before verify() is what makes the back-off a lockout rather than a message.
            val state = lockedState()
            if (PinLockout.isLocked(state, elapsed)) {
                pin.text.clear()
                errorView.text = noticeText()
                return@setOnClickListener
            }
            val entered = pin.text.toString()
            if (pinStore.verify(entered)) {
                // The only thing that resets the count.
                attemptStore.clear()
                TamperState.grantGrace(this, now + TamperScreenPolicy.GRACE_MS)
                setResult(RESULT_OK)
                finish()
            } else {
                val failed = PinLockout.recordFailure(state, now, elapsed, bootCount())
                if (PinLockout.shouldAlert(failed)) {
                    // One alert per lockout: the parent is told the gate is closed, not told again for each
                    // further attempt inside the same closed gate.
                    attemptStore.write(PinLockout.markedAlerted(failed))
                    TamperAlertWorker.enqueue(
                        this,
                        // #792 (Antigravity B1): the lockout has its own type. Sent as TYPE_GUARD_TRIGGERED it
                        // carried a window of 5+ and TamperAlertWorker.bodyFor replaced this sentence with the
                        // five-attempt aggregation, so the parent never read the lock duration.
                        TamperAlertWorker.TYPE_PIN_LOCKOUT,
                        detail = "Parent PIN locked for ${PinLockout.lockWindowMs(failed.failures) / 60_000} minute(s) " +
                            "after ${failed.failures} wrong tries.",
                        eventAtMs = failed.lastFailureMs,
                        attemptCount = failed.failures,
                    )
                } else {
                    attemptStore.write(failed)
                }
                pin.text.clear()
                val attempts = failed.failures
                // #484: the fifth wrong PIN still lands Home. The lockout is what the next open reports.
                if (attempts >= MAX_ATTEMPTS) goHome()
                // #792's notice first: while the gate is shut, the child is told how long, not just "too many".
                // The two sentences below are main's (#725's Arabic campaign) and are kept as they are.
                errorView.text = when {
                    PinLockout.isLocked(failed, SystemClock.elapsedRealtime()) -> noticeText()
                    attempts >= MAX_ATTEMPTS -> getString(R.string.pin_gate_too_many)
                    else -> getString(R.string.pin_gate_wrong)
                }
            }
        }
        back.setOnClickListener { goHome() }

        setContentView(
            LinearLayout(this).apply {
                orientation = LinearLayout.VERTICAL
                gravity = Gravity.CENTER
                // N1 (Antigravity): the background comes from the palette too, so a token swap moves both
                // colours together — the text already did, and half a palette is how one of them drifts.
                setBackgroundColor(GuardPalette.BACKGROUND)
                setPadding(64, 64, 64, 64)
                addView(
                    TextView(this@TamperGuardActivity).apply {
                        text = getString(R.string.pin_gate_title)
                        setTextColor(0xFFFFFFFF.toInt())
                        textSize = 26f
                        gravity = Gravity.CENTER
                    },
                )
                addView(
                    TextView(this@TamperGuardActivity).apply {
                        text = getString(
                            when (reason) {
                                REASON_REPAIR -> R.string.pin_gate_reason_repair
                                REASON_REMOVE -> R.string.pin_gate_reason_remove
                                REASON_RING -> R.string.pin_gate_reason_ring
                                else -> R.string.pin_gate_reason_settings
                            },
                        )
                        setTextColor(0xFFAEB0B8.toInt())
                        textSize = 16f
                        gravity = Gravity.CENTER
                        setPadding(0, 24, 0, 40)
                    },
                )
                addView(pin)
                addView(errorView)
                addView(unlock)
                addView(back)
            },
        )
    }

    // #533 review: the guard's debounce reads these — it may skip a protection screen only while the gate is in
    // front. onPause completes before the next activity resumes, so a screen that comes back over a paused gate
    // is always judged.
    //
    // #792 (Antigravity S1): both guard activities are `singleTask`, so a re-entry through Recents or
    // `onNewIntent` never re-runs `onCreate`. A lockout that expired while the screen was backgrounded left its
    // banner up with Continue disabled, and a live one kept the button in whatever state the field last set.
    // Both are refreshed from the stored state on every resume.
    override fun onResume() {
        super.onResume()
        GuardGateState.lastResumedMs = System.currentTimeMillis()
        GuardGateState.showing = true
        onSharingChanged(isInMultiWindowMode)
        refreshLockoutUi()
    }

    /**
     * The banner and the button, from the stored state — see [onResume] (#792, Antigravity S1).
     *
     * Codex on #792: running this only in `onResume` leaves both stale for the rest of the window. A screen
     * that stays in front when the lockout ends keeps "locked" text above a Continue that only becomes
     * pressable once the parent types again or leaves and returns. So the refresh also schedules itself for
     * the instant the window ends — one delayed post, cancelled whenever the state says unlocked and in
     * [onDestroy], which keeps it from outliving the screen.
     */
    private fun refreshLockoutUi() {
        if (!::errorView.isInitialized) return
        val elapsed = SystemClock.elapsedRealtime()
        val state = lockedState()
        val locked = PinLockout.isLocked(state, elapsed)
        errorView.text = if (locked) noticeText() else ""
        syncUnlockEnabledRef?.invoke()
        lockoutRefresh?.let { handler.removeCallbacks(it) }
        lockoutRefresh = null
        if (!locked) return
        // A quarter second past the boundary: the reachability check is `now - lastFailure < window`, so
        // posting exactly at the boundary can land one millisecond early and re-arm itself forever.
        val delayMs = PinLockout.remainingMs(state, elapsed) + LOCKOUT_REFRESH_SLACK_MS
        handler.postDelayed(
            Runnable {
                lockoutRefresh = null
                refreshLockoutUi()
            }.also { lockoutRefresh = it },
            delayMs,
        )
    }

    /** Posts the lockout re-check; see [refreshLockoutUi]. Main looper: it touches views. */
    private val handler = android.os.Handler(android.os.Looper.getMainLooper())
    private var lockoutRefresh: Runnable? = null

    /** A quarter second of slack past the window; see the delay in [refreshLockoutUi]. */
    private val LOCKOUT_REFRESH_SLACK_MS = 250L

    private fun bootCount(): Int = runCatching {
        Settings.Global.getInt(contentResolver, Settings.Global.BOOT_COUNT, PinLockout.NO_BOOT)
    }.getOrDefault(PinLockout.NO_BOOT)

    /** The stored state with a window carried across a reboot re-anchored to now (#792, Claude's condition). */
    private fun lockedState(): PinLockout.State {
        val stored = attemptStore.read()
        val state = PinLockout.anchored(stored, System.currentTimeMillis(), SystemClock.elapsedRealtime(), bootCount())
        if (state != stored) attemptStore.write(state)
        return state
    }

    private fun noticeText(): String {
        val minutes = PinLockout.remainingMinutes(lockedState(), SystemClock.elapsedRealtime())
        return resources.getQuantityString(R.plurals.pin_locked_notice, minutes, minutes)
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

    /** A re-check posted for a lockout boundary must not outlive the screen (see [refreshLockoutUi]). */
    override fun onDestroy() {
        lockoutRefresh?.let { handler.removeCallbacks(it) }
        lockoutRefresh = null
        super.onDestroy()
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
