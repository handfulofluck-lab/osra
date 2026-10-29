package com.familyshield.agent.services

import android.accessibilityservice.AccessibilityService
import android.app.Notification
import android.app.PendingIntent
import android.graphics.Color
import android.graphics.PixelFormat
import android.media.AudioManager
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.util.Log
import android.view.Gravity
import android.view.View
import android.view.WindowManager
import android.view.accessibility.AccessibilityEvent
import com.familyshield.agent.enforcement.BypassAlertFloor
import com.familyshield.agent.enforcement.CallAction
import com.familyshield.agent.enforcement.CallAudioMode
import com.familyshield.agent.enforcement.CallBlockPolicy
import com.familyshield.agent.enforcement.CallNotice
import com.familyshield.agent.enforcement.CallParcel
import com.familyshield.agent.security.TamperAlertWorker

/**
 * Issue #444: the Android side of [CallBlockPolicy]. It reads call notifications from accessibility
 * events, follows the audio mode, keeps the blocked apps' `CallStyle` decline and hang-up intents, and
 * carries out what the policy decides. All decisions are in the policy; this class only translates.
 *
 * What is read from another app's notification: its category, whether it is ongoing, `when`, and the
 * three `CallStyle` intent extras. Never its title, text or people (#446 confirmed the extras suffice).
 * No NotificationListener: the Play build keeps that Full-only, and these events need none.
 */
class CallEnforcer(
    private val service: AccessibilityService,
    private val isBlocked: (String) -> Boolean,
    private val isEssential: (String) -> Boolean,
    floor: BypassAlertFloor,
) {
    private val policy = CallBlockPolicy(floor = floor)
    private val audio = service.getSystemService(AudioManager::class.java)
    private val main = Handler(Looper.getMainLooper())
    private val declineIntents = HashMap<String, PendingIntent>()
    private val hangUpIntents = HashMap<String, PendingIntent>()
    private var cover: View? = null
    private var ticking = false

    private val modeListener: Any? = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
        AudioManager.OnModeChangedListener { mode -> apply(policy.onAudioMode(map(mode), isBlocked, now())) }
    } else {
        null
    }

    private val tick = object : Runnable {
        override fun run() {
            apply(policy.onAudioMode(currentMode(), isBlocked, now()))
            if (policy.coverShown || currentMode() != CallAudioMode.NORMAL) {
                main.postDelayed(this, TICK_MS)
            } else {
                ticking = false
            }
        }
    }

    fun onConnected() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            runCatching { audio?.addOnModeChangedListener(service.mainExecutor, modeListener as AudioManager.OnModeChangedListener) }
        }
    }

    fun onDestroy() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            runCatching { audio?.removeOnModeChangedListener(modeListener as AudioManager.OnModeChangedListener) }
        }
        main.removeCallbacks(tick)
        removeCover()
    }

    /** A `TYPE_NOTIFICATION_STATE_CHANGED` event. */
    fun onNotification(event: AccessibilityEvent) {
        val pkg = event.packageName?.toString() ?: return
        // Our own foreground-service notifications are neither a ring nor an allowed app's post.
        if (pkg == service.packageName) return
        val notification = runCatching { event.parcelableData as? Notification }.getOrNull()
        val parcel = notification?.let { n ->
            val extras = n.extras
            val decline = extras?.parcelable(EXTRA_DECLINE)
            val hangUp = extras?.parcelable(EXTRA_HANG_UP)
            if (decline != null) declineIntents[pkg] = decline
            if (hangUp != null) hangUpIntents[pkg] = hangUp
            CallParcel(
                isCall = n.category == Notification.CATEGORY_CALL,
                hasDecline = decline != null,
                hasHangUp = hangUp != null,
                ongoing = n.flags and Notification.FLAG_ONGOING_EVENT != 0,
                postedAt = n.`when`,
            )
        }
        // The mode first, so the policy judges the notice in the current call state.
        apply(policy.onAudioMode(currentMode(), isBlocked, now()))
        apply(policy.onNotification(CallNotice(pkg, parcel), isBlocked, isEssential, now()))
    }

    /**
     * Any other event: below API 31 this is the only source of the audio mode. From 31 the mode listener
     * and the tick cover it, so the binder read is skipped on the window-content hot path (#449 review).
     */
    fun onEvent() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.S) apply(policy.onAudioMode(currentMode(), isBlocked, now()))
    }

    private fun apply(actions: List<CallAction>) {
        for (action in actions) {
            when (action) {
                is CallAction.Decline -> send(declineIntents[action.pkg], "decline", action.pkg)
                is CallAction.HangUp -> send(hangUpIntents[action.pkg], "hang-up", action.pkg)
                CallAction.ShowRingCover -> showCover()
                CallAction.RemoveRingCover -> removeCover()
                is CallAction.ReportCall -> {
                    Log.w(TAG, "blocked call by ${action.pkg} still up after the hang-up; telling the parent (#444)")
                    TamperAlertWorker.enqueue(
                        service,
                        TamperAlertWorker.TYPE_BLOCK_BYPASS,
                        eventAtMs = action.callStartMs,
                        app = action.pkg,
                        layout = "call",
                    )
                }
            }
        }
        if (!ticking && (policy.coverShown || currentMode() != CallAudioMode.NORMAL)) {
            ticking = true
            main.postDelayed(tick, TICK_MS)
        }
    }

    private fun send(intent: PendingIntent?, what: String, pkg: String) {
        if (intent == null) {
            Log.w(TAG, "$what for $pkg: no intent cached")
            return
        }
        runCatching { intent.send() }
            .onSuccess { Log.i(TAG, "$what sent for blocked $pkg (#444)") }
            .onFailure { Log.w(TAG, "$what for $pkg failed", it) }
    }

    private fun showCover() {
        if (cover != null) return
        val wm = service.getSystemService(WindowManager::class.java) ?: return
        val view = View(service).apply { setBackgroundColor(Color.BLACK) }
        val params = WindowManager.LayoutParams(
            WindowManager.LayoutParams.MATCH_PARENT,
            WindowManager.LayoutParams.MATCH_PARENT,
            WindowManager.LayoutParams.TYPE_ACCESSIBILITY_OVERLAY,
            WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE or
                WindowManager.LayoutParams.FLAG_LAYOUT_IN_SCREEN or
                WindowManager.LayoutParams.FLAG_SHOW_WHEN_LOCKED,
            PixelFormat.OPAQUE,
        ).apply { gravity = Gravity.TOP or Gravity.START }
        runCatching { wm.addView(view, params) }
            .onSuccess { cover = view; Log.i(TAG, "ring cover up over a blocked app's call (#444)") }
            .onFailure { Log.w(TAG, "ring cover failed", it) }
    }

    private fun removeCover() {
        val view = cover ?: return
        runCatching { service.getSystemService(WindowManager::class.java)?.removeViewImmediate(view) }
        cover = null
    }

    private fun currentMode(): CallAudioMode = map(runCatching { audio?.mode }.getOrNull() ?: AudioManager.MODE_NORMAL)

    private fun map(mode: Int): CallAudioMode = when (mode) {
        AudioManager.MODE_NORMAL -> CallAudioMode.NORMAL
        AudioManager.MODE_RINGTONE -> CallAudioMode.RINGTONE
        AudioManager.MODE_IN_CALL -> CallAudioMode.IN_CALL
        AudioManager.MODE_IN_COMMUNICATION -> CallAudioMode.IN_COMMUNICATION
        else -> CallAudioMode.OTHER
    }

    private fun now() = System.currentTimeMillis()

    @Suppress("DEPRECATION")
    private fun android.os.Bundle.parcelable(key: String): PendingIntent? =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) getParcelable(key, PendingIntent::class.java)
        else getParcelable(key) as? PendingIntent

    private companion object {
        const val TAG = "CallEnforcer"
        const val TICK_MS = 1_000L

        // Notification.EXTRA_DECLINE_INTENT / EXTRA_HANG_UP_INTENT (API 31); the literal keys work on older builds too.
        const val EXTRA_DECLINE = "android.declineIntent"
        const val EXTRA_HANG_UP = "android.hangUpIntent"
    }
}
