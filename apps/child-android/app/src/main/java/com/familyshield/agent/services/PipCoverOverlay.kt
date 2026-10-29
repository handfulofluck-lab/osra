package com.familyshield.agent.services

import android.content.Context
import android.graphics.Color
import android.graphics.PixelFormat
import android.util.Log
import android.view.Gravity
import android.view.View
import android.view.WindowManager
import com.familyshield.agent.enforcement.PipCoverAction
import com.familyshield.agent.enforcement.PipCoverDecision
import com.familyshield.agent.enforcement.WindowBounds

/**
 * Issue #175: an opaque view over a blocked app's picture-in-picture window. Android keeps a PiP
 * window above any full-screen activity, so the block screen alone leaves the video playing in its
 * corner. Only an accessibility service may add a `TYPE_ACCESSIBILITY_OVERLAY` window, and it needs
 * no extra permission; the view takes touches (so play and expand cannot be tapped) but never focus.
 *
 * [PipCoverDecision] decides add, move, keep and remove; this class only applies the answer. Every
 * WindowManager call is wrapped: a failure is logged and leaves the block screen path unaffected.
 */
class PipCoverOverlay(private val context: Context) {
    private val windowManager = context.getSystemService(WindowManager::class.java)
    private var view: View? = null
    private var bounds: WindowBounds? = null

    /** [blockedPip] is the blocked PiP window's rectangle, or null when there is none. */
    fun update(blockedPip: WindowBounds?) {
        when (val action = PipCoverDecision.decide(blockedPip, bounds)) {
            PipCoverAction.Keep -> Unit
            is PipCoverAction.Add -> add(action.bounds)
            is PipCoverAction.Move -> move(action.bounds)
            PipCoverAction.Remove -> remove()
        }
    }

    fun remove() {
        val current = view ?: return
        runCatching { windowManager?.removeViewImmediate(current) }
            .onFailure { Log.w(TAG, "PiP cover: remove failed", it) }
        view = null
        bounds = null
    }

    private fun add(target: WindowBounds) {
        val wm = windowManager ?: return
        val cover = View(context).apply { setBackgroundColor(Color.BLACK) }
        runCatching { wm.addView(cover, params(target)) }
            .onSuccess {
                view = cover
                bounds = target
                Log.i(TAG, "PiP cover added over a blocked picture-in-picture window (#175)")
            }
            .onFailure { Log.w(TAG, "PiP cover: add failed", it) }
    }

    private fun move(target: WindowBounds) {
        val current = view ?: return add(target)
        runCatching { windowManager?.updateViewLayout(current, params(target)) }
            .onSuccess { bounds = target }
            .onFailure { Log.w(TAG, "PiP cover: move failed", it) }
    }

    private fun params(target: WindowBounds) = WindowManager.LayoutParams(
        target.width,
        target.height,
        WindowManager.LayoutParams.TYPE_ACCESSIBILITY_OVERLAY,
        WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE or
            WindowManager.LayoutParams.FLAG_LAYOUT_IN_SCREEN or
            WindowManager.LayoutParams.FLAG_LAYOUT_NO_LIMITS,
        PixelFormat.OPAQUE,
    ).apply {
        gravity = Gravity.TOP or Gravity.START
        x = target.left
        y = target.top
    }

    private companion object {
        const val TAG = "PipCoverOverlay"
    }
}
