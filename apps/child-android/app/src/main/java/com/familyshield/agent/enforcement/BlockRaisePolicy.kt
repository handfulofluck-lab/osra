package com.familyshield.agent.enforcement

/** What to do about one blocked package seen in one accessibility event (issue #175). */
data class BlockRaise(
    /** Start the block (or time-limit) screen now. */
    val raise: Boolean,
    /** Send `GLOBAL_ACTION_HOME` first, so the blocked app is no longer the window that comes back. */
    val goHome: Boolean,
    /** The blocked app is still visible after every raise this state allows: tell the parent, once. */
    val reportBypass: Boolean,
    /** When this episode began; with the package and layout it names the bypass alert (dedupe key). */
    val episodeStartMs: Long = 0L,
) {
    companion object {
        val NOTHING = BlockRaise(raise = false, goHome = false, reportBypass = false)
    }
}

/**
 * Issue #175, the two cases #194 left open.
 *
 * **Normal layout (the Meet case, 2026-10-20).** A blocked call app's in-call screen comes back on top
 * of the block screen within a second. The retry budget, written for PiP and split screen where the
 * platform refuses to change state, turned that into a permanent "leave it alone", and the call carried
 * on. In the normal layout there is no budget any more: while the blocked app is the active window it
 * is sent Home and the block screen is raised again, at most once per [debounceMs] per package.
 *
 * **Picture-in-picture and split screen.** These can be states the platform will not change, so a
 * bounded number of raises still applies: [multiWindowRaises] per episode, each sending Home first in
 * PiP. If the blocked app is still visible after that, the parent hears about it once per episode
 * ([BlockRaise.reportBypass]) instead of the failure being logged and forgotten.
 *
 * An **episode** is one blocked package in one layout. It ends when an event shows no blocked app in
 * a window ([noBlockedWindow]), or when the package or the layout changes, so the next time the child
 * puts a blocked app in PiP it starts afresh. The episode deliberately does not follow
 * [WindowSnapshot.signature]: that string names the active window too, and our own block screen
 * becoming active would restart the count on every raise.
 *
 * Pure by construction (the clock is a parameter), so the JVM suite pins every bound.
 */
class BlockRaisePolicy(
    private val debounceMs: Long = DEFAULT_DEBOUNCE_MS,
    private val multiWindowRaises: Int = DEFAULT_MULTI_WINDOW_RAISES,
    private val floor: BypassAlertFloor = BypassAlertFloor(),
) {
    private val lastRaiseMs = HashMap<String, Long>()
    private var episode: String? = null
    private var episodeStartMs = 0L
    private var episodeRaises = 0
    private var bypassReported = false

    fun decide(pkg: String, layout: WindowLayout, blockedIsActive: Boolean, nowMs: Long): BlockRaise {
        val key = "$pkg|$layout"
        if (key != episode) {
            episode = key
            episodeStartMs = nowMs
            episodeRaises = 0
            bypassReported = false
        }
        val last = lastRaiseMs[pkg]
        // A backwards clock (now < last) must not suppress raises forever, as in AppBlocker.
        val debounced = last != null && nowMs - last in 0 until debounceMs
        if (layout == WindowLayout.NORMAL) {
            if (debounced) return BlockRaise.NOTHING
            lastRaiseMs[pkg] = nowMs
            return BlockRaise(raise = true, goHome = blockedIsActive, reportBypass = false)
        }
        if (episodeRaises < multiWindowRaises) {
            if (debounced) return BlockRaise.NOTHING
            lastRaiseMs[pkg] = nowMs
            episodeRaises++
            return BlockRaise(
                raise = true,
                goHome = layout == WindowLayout.PICTURE_IN_PICTURE || blockedIsActive,
                reportBypass = false,
            )
        }
        if (bypassReported) return BlockRaise.NOTHING
        bypassReported = true
        // #443 review: a PiP window that blinks out of getWindows() and back starts a new episode; the
        // raises may restart, the parent hears once per floor.
        if (!floor.tryReport(pkg, nowMs)) return BlockRaise.NOTHING
        return BlockRaise(raise = false, goHome = false, reportBypass = true, episodeStartMs = episodeStartMs)
    }

    /** An event with no blocked app in any window ends the episode. */
    fun noBlockedWindow() {
        episode = null
        episodeRaises = 0
        bypassReported = false
    }

    companion object {
        /** The issue's spacing: never faster than once a second per package. */
        const val DEFAULT_DEBOUNCE_MS: Long = 1_000L

        /** "If the PiP window survives two tries": two raises, then the parent is told. */
        const val DEFAULT_MULTI_WINDOW_RAISES: Int = 2

        /** One bypass alert per app per ten minutes, however often the episode restarts ([BypassAlertFloor]). */
        const val DEFAULT_BYPASS_FLOOR_MS: Long = BypassAlertFloor.DEFAULT_FLOOR_MS
    }
}
