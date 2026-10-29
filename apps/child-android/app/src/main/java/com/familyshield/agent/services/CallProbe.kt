package com.familyshield.agent.services

import android.accessibilityservice.AccessibilityService
import android.app.Notification
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
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
import android.view.accessibility.AccessibilityNodeInfo
import android.view.accessibility.AccessibilityWindowInfo
import androidx.core.content.ContextCompat
import com.familyshield.agent.BuildConfig

/**
 * Issue #444, measurement only, **debug builds only** (every entry point returns at once when
 * `BuildConfig.DEBUG` is false, and R8 drops it from release). It answers Claude's four questions on
 * the Flip4 from one `adb logcat -s CallProbe` run, before any enforcement code is written:
 *
 * - **Q1** — does a `TYPE_NOTIFICATION_STATE_CHANGED` event from a blocked call app reach the service,
 *   carrying a [Notification] of `CATEGORY_CALL`? (`notif …` lines; the event type is added at runtime
 *   here, so the shipped accessibility config is unchanged.)
 * - **Q2** — is a full-screen `TYPE_ACCESSIBILITY_OVERLAY` drawn above the heads-up / full-screen call
 *   UI? Off by default; `adb shell am broadcast -a com.familyshield.agent.DEBUG_CALL_PROBE --ez cover true`
 *   turns it on, and each `CATEGORY_CALL` notification from a blocked package then draws a red
 *   translucent cover for 10 s (`cover …` lines; whether it is **above** the call UI is read off the screen).
 * - **Q3** — can the hang-up be found without matching text? Each call notification logs its
 *   `CallStyle` intents (`android.hangUpIntent` / `declineIntent` / `answerIntent`) and every action's
 *   `semanticAction`; while a call is up, the view ids of the blocked app's clickable nodes are logged.
 * - **Q4** — does `AudioManager.mode` say `MODE_IN_COMMUNICATION` while the blocked app's call is up,
 *   and back to normal when it ends? (`audio mode …` lines, with the visible packages at each change.)
 *
 * Nothing here blocks, ends or alters a call. Action titles are app UI text, not user data.
 */
object CallProbe {
    private const val TAG = "CallProbe"
    const val ACTION_CONFIGURE = "com.familyshield.agent.DEBUG_CALL_PROBE"
    private const val COVER_MS = 10_000L
    private const val MAX_IDS = 40

    private var coverOnCall = false
    private var lastMode = Int.MIN_VALUE
    private var cover: View? = null
    private val main by lazy { Handler(Looper.getMainLooper()) }

    private val receiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context?, intent: Intent?) {
            coverOnCall = intent?.getBooleanExtra("cover", false) == true
            Log.i(TAG, "configured: cover on call notification = $coverOnCall")
        }
    }

    fun onConnected(service: AccessibilityService) {
        if (!BuildConfig.DEBUG) return
        runCatching {
            service.serviceInfo = service.serviceInfo.apply {
                eventTypes = eventTypes or AccessibilityEvent.TYPE_NOTIFICATION_STATE_CHANGED
            }
        }.onFailure { Log.w(TAG, "could not add notification events", it) }
        // Exported so `adb shell am broadcast` (the shell uid) reaches it; debug builds only.
        runCatching {
            ContextCompat.registerReceiver(service, receiver, IntentFilter(ACTION_CONFIGURE), ContextCompat.RECEIVER_EXPORTED)
        }
        Log.i(TAG, "probe on (#444): notifications=yes, cover=$coverOnCall")
    }

    fun onDisconnected(service: AccessibilityService) {
        if (!BuildConfig.DEBUG) return
        runCatching { service.unregisterReceiver(receiver) }
        removeCover(service)
    }

    /** Q1, Q2, Q3: one line per notification event, plus the CallStyle intents and actions of a call. */
    fun onNotification(service: AccessibilityService, event: AccessibilityEvent, isBlocked: (String) -> Boolean) {
        if (!BuildConfig.DEBUG) return
        val pkg = event.packageName?.toString() ?: return
        val notification = runCatching { event.parcelableData as? Notification }.getOrNull()
        val blocked = runCatching { isBlocked(pkg) }.getOrDefault(false)
        if (notification == null) {
            Log.i(TAG, "notif pkg=$pkg blocked=$blocked parcelable=none")
            return
        }
        val extras = notification.extras
        val isCall = notification.category == Notification.CATEGORY_CALL
        Log.i(
            TAG,
            "notif pkg=$pkg blocked=$blocked category=${notification.category} " +
                "template=${extras?.getString(Notification.EXTRA_TEMPLATE)} " +
                "fullScreen=${notification.fullScreenIntent != null} " +
                "ongoing=${notification.flags and Notification.FLAG_ONGOING_EVENT != 0} " +
                "mode=${modeName(audioMode(service))}",
        )
        if (!isCall) return
        for (key in listOf("android.hangUpIntent", "android.declineIntent", "android.answerIntent")) {
            Log.i(TAG, "  callstyle $key present=${extras?.containsKey(key) == true}")
        }
        notification.actions.orEmpty().forEachIndexed { i, action ->
            val semantic = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) action.semanticAction else -1
            Log.i(TAG, "  action[$i] semantic=$semantic intent=${action.actionIntent != null} title='${action.title}'")
        }
        if (coverOnCall && blocked) showCover(service)
    }

    /** Q4 and the in-call half of Q3: audio-mode changes, and the clickable ids while a call is up. */
    fun onWindows(service: AccessibilityService, visible: List<String>, isBlocked: (String) -> Boolean) {
        if (!BuildConfig.DEBUG) return
        val mode = audioMode(service)
        if (mode != lastMode) {
            Log.i(TAG, "audio mode ${modeName(lastMode)} -> ${modeName(mode)} visible=$visible")
            lastMode = mode
            if (mode == AudioManager.MODE_IN_COMMUNICATION || mode == AudioManager.MODE_IN_CALL) {
                logClickableIds(service, isBlocked)
            }
        }
    }

    private fun logClickableIds(service: AccessibilityService, isBlocked: (String) -> Boolean) {
        for (window in runCatching { service.windows }.getOrNull().orEmpty()) {
            try {
                if (window.type != AccessibilityWindowInfo.TYPE_APPLICATION) continue
                val root = runCatching { window.root }.getOrNull() ?: continue
                try {
                    val pkg = root.packageName?.toString() ?: continue
                    if (!isBlocked(pkg)) continue
                    val ids = ArrayList<String>()
                    collectIds(root, ids)
                    Log.i(TAG, "  in-call ids pkg=$pkg pip=${window.isInPictureInPictureMode} ids=$ids")
                } finally {
                    runCatching { root.recycle() }
                }
            } finally {
                runCatching { window.recycle() }
            }
        }
    }

    private fun collectIds(node: AccessibilityNodeInfo, out: MutableList<String>, depth: Int = 0) {
        if (out.size >= MAX_IDS || depth > 30) return
        if (node.isClickable) out.add(node.viewIdResourceName ?: "(no id)")
        for (i in 0 until node.childCount) {
            val child = runCatching { node.getChild(i) }.getOrNull() ?: continue
            try {
                collectIds(child, out, depth + 1)
            } finally {
                runCatching { child.recycle() }
            }
        }
    }

    private fun showCover(service: AccessibilityService) {
        if (cover != null) return
        val wm = service.getSystemService(WindowManager::class.java) ?: return
        val view = View(service).apply { setBackgroundColor(Color.argb(160, 200, 0, 0)) }
        val params = WindowManager.LayoutParams(
            WindowManager.LayoutParams.MATCH_PARENT,
            WindowManager.LayoutParams.MATCH_PARENT,
            WindowManager.LayoutParams.TYPE_ACCESSIBILITY_OVERLAY,
            WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE or WindowManager.LayoutParams.FLAG_LAYOUT_IN_SCREEN,
            PixelFormat.TRANSLUCENT,
        ).apply { gravity = Gravity.TOP or Gravity.START }
        runCatching { wm.addView(view, params) }
            .onSuccess {
                cover = view
                Log.i(TAG, "cover added over the screen for ${COVER_MS / 1000} s — is it above the call UI?")
                main.postDelayed({ removeCover(service) }, COVER_MS)
            }
            .onFailure { Log.w(TAG, "cover failed", it) }
    }

    private fun removeCover(service: AccessibilityService) {
        val view = cover ?: return
        runCatching { service.getSystemService(WindowManager::class.java)?.removeViewImmediate(view) }
        cover = null
        Log.i(TAG, "cover removed")
    }

    private fun audioMode(context: Context): Int =
        runCatching { context.getSystemService(AudioManager::class.java)?.mode }.getOrNull() ?: Int.MIN_VALUE

    private fun modeName(mode: Int): String = when (mode) {
        AudioManager.MODE_NORMAL -> "NORMAL"
        AudioManager.MODE_RINGTONE -> "RINGTONE"
        AudioManager.MODE_IN_CALL -> "IN_CALL"
        AudioManager.MODE_IN_COMMUNICATION -> "IN_COMMUNICATION"
        Int.MIN_VALUE -> "unknown"
        else -> mode.toString()
    }
}
