package com.familyshield.agent.commands

/**
 * #734 (Flip4, 13 Nov 20:24Z): Home is not a way out of a ring, and it used to be.
 *
 * `RingActivity` offers exactly one way out — the parent PIN — and swallows Back and the volume keys. Home is
 * a system action no activity can swallow: the screen went to the back of its own task (invisible since #731
 * set `taskAffinity=""` and `excludeFromRecents`), the alarm kept ringing at full volume, and nothing on the
 * phone could stop it — only the parent's `stop_ring` or the ring's own cap.
 *
 * The service that already watches the foreground window brings the ring screen back while the ring is
 * running, so the rule lives here, free of Android types, and the activity's single exit stays the only exit.
 *
 * **Why the debounce is not optional:** every window change while an app is opening fires this, and an
 * unthrottled `startActivity` from an accessibility service would relaunch the screen dozens of times a
 * second, which on a low-end phone is a stutter the child would notice.
 */
object RingReentryPolicy {

    /** Minimum gap between two launches of the ring screen. One ring produced ~30 window changes on the Flip4. */
    const val DEBOUNCE_MS: Long = 1_500

    /**
     * True when the ring screen must be brought back in front of [foreground].
     *
     * - not while no ring is running: the screen is not owed to anyone;
     * - not when the window in front is **our own package** — that is the ring screen itself, or the PIN gate
     *   it opened, and relaunching over our own screen is the one way to make the exit unreachable;
     * - not when the window cannot be named: "I do not know what is in front" is not evidence that the ring
     *   screen is gone;
     * - not more often than [DEBOUNCE_MS], and never when the clock has gone backwards (a debounce that a
     *   moved clock can satisfy forever would leave the ring unreachable, which is the bug being fixed).
     */
    fun shouldRestore(
        isRinging: Boolean,
        foreground: String?,
        ownPackage: String,
        nowMs: Long,
        lastRestoreMs: Long,
    ): Boolean {
        if (!isRinging) return false
        if (foreground == null) return false
        if (foreground == ownPackage) return false
        val since = nowMs - lastRestoreMs
        if (lastRestoreMs != 0L && (since < 0L || since < DEBOUNCE_MS)) return false
        return true
    }
}
