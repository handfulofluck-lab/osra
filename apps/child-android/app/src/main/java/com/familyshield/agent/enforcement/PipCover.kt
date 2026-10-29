package com.familyshield.agent.enforcement

/** A window's rectangle in screen coordinates (`AccessibilityWindowInfo.getBoundsInScreen`). */
data class WindowBounds(val left: Int, val top: Int, val right: Int, val bottom: Int) {
    val width: Int get() = right - left
    val height: Int get() = bottom - top
    val isEmpty: Boolean get() = width <= 0 || height <= 0
}

/** What the accessibility service does with its PiP cover view this event. */
sealed interface PipCoverAction {
    /** Nothing changes. */
    data object Keep : PipCoverAction

    /** Put a cover over [bounds]. */
    data class Add(val bounds: WindowBounds) : PipCoverAction

    /** The blocked PiP window moved or resized: follow it. */
    data class Move(val bounds: WindowBounds) : PipCoverAction

    /** The blocked PiP window is gone (or is no longer blocked): take the cover away. */
    data object Remove : PipCoverAction
}

/**
 * Issue #175, reopened on #194: Android keeps a PiP window above a full-screen activity, so the block
 * screen alone never hides a blocked video in PiP. The accessibility service draws its own
 * `TYPE_ACCESSIBILITY_OVERLAY` view over the PiP window's bounds while a blocked package is in PiP,
 * and removes it when that window goes. Whether that layer sits above the pinned task on One UI is
 * the hardware row's measurement; this decides only add, move, keep and remove.
 */
object PipCoverDecision {
    fun decide(blockedPip: WindowBounds?, current: WindowBounds?): PipCoverAction {
        val target = blockedPip?.takeUnless { it.isEmpty }
        return when {
            target == null && current == null -> PipCoverAction.Keep
            target == null -> PipCoverAction.Remove
            current == null -> PipCoverAction.Add(target)
            target == current -> PipCoverAction.Keep
            else -> PipCoverAction.Move(target)
        }
    }
}
