package com.familyshield.agent.security

import com.familyshield.agent.enforcement.WindowBounds

/** One application window on screen, as the guard's cover sees it. */
data class GuardWindow(
    /** Whether [TamperScreenPolicy.classify] named this window a protection screen. */
    val protected: Boolean,
    val bounds: WindowBounds?,
)

/**
 * osra-security#7 (Flip4, 11 Nov): the PIN gate is an activity, and an activity cannot be above every window.
 * When a protection screen shares the screen (split screen, a pop-up or freeform window), the gate either leaves
 * (it refuses to share, #546) or sits under a pop-up that One UI keeps on top. So while a protection screen is
 * one of two or more visible application windows, the accessibility service covers that window's bounds with
 * its own `TYPE_ACCESSIBILITY_OVERLAY` view, which is above every application window, pop-ups included. The
 * cover takes touches and never focus, so nothing on that screen can be pressed, and the rest of the phone
 * stays usable. It comes off when the screen is gone, or when a parent PIN starts the grace window.
 *
 * A full-screen protection screen gets no cover: the gate opens full-screen over it as before, and a cover there
 * would sit above the gate itself (both are briefly visible while the gate comes up). "Full-screen" is "as large
 * as all the visible application windows together", so the rule needs no display size.
 */
object GuardCoverPolicy {

    /**
     * The rectangle to cover, or null for no cover. [guardActive] is "a PIN is set and no grace window is
     * running" ([TamperScreenPolicy.shouldGuard]'s other two inputs). Two protection windows are covered as one
     * rectangle around both, which never leaves either uncovered.
     */
    fun cover(windows: List<GuardWindow>, guardActive: Boolean): WindowBounds? {
        if (!guardActive || windows.size < 2) return null
        val screen = union(windows.mapNotNull { it.bounds }.filterNot { it.isEmpty }) ?: return null
        val hits = windows.filter { it.protected }.mapNotNull { it.bounds }.filterNot { it.isEmpty || it == screen }
        return union(hits)
    }

    private fun union(hits: List<WindowBounds>): WindowBounds? {
        if (hits.isEmpty()) return null
        return WindowBounds(
            left = hits.minOf { it.left },
            top = hits.minOf { it.top },
            right = hits.maxOf { it.right },
            bottom = hits.maxOf { it.bottom },
        )
    }

    /** Whether the gate should be launched (and the parent told) for this event: only when a cover goes up. */
    fun stepIn(previous: WindowBounds?, next: WindowBounds?): Boolean = previous == null && next != null
}
