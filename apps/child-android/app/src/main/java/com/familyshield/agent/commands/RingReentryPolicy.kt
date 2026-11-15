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
 */
object RingReentryPolicy {

    /** Minimum gap between two launches of the ring screen. One ring produced ~30 window changes on the Flip4. */
    const val DEBOUNCE_MS: Long = 1_500

    /** What the service should do about the window in front while a ring is running. */
    enum class Reentry {
        /** Bring the ring screen back now. */
        RESTORE,

        /**
         * Too soon since the last launch, but the window in front is still not the ring screen: come back at
         * the end of the debounce. Dropping it would leave the launcher in front until something else opens
         * (Claude's V2 on #802), which is the same escape by a slower route.
         */
        DEFER,

        /** Nothing to do: no ring, no named window, or the ring screen (or its PIN gate) is already in front. */
        IGNORE,
    }

    /**
     * The classes that *are* the ring and its exit. Exempting the whole package was the hole in the first
     * version (osra-security#31): the child app has a launcher activity, so during a ring the child could press
     * Home, open the OSRA child app from the launcher, and the policy saw "our own package" and stood down
     * while the alarm kept ringing.
     */
    private val RING_SCREEN_CLASSES = listOf(
        "RingActivity",
        "TamperGuardActivity",
        "TamperGuardTaskActivity",
    )

    /**
     * Decides what to do about [foreground] while a ring runs.
     *
     * - not while no ring is running: the screen is not owed to anyone;
     * - not on an unnamed window: "I do not know what is in front" is not evidence that the ring screen is
     *   gone;
     * - **ignore only the ring screen and the PIN gate**, by class, never the rest of our package;
     * - [nowElapsedMs] is `SystemClock.elapsedRealtime()` and [lastRestoreElapsedMs] the same clock at the last
     *   launch, so a wall-clock change can neither open the gate early nor hold it shut (Claude's V1).
     */
    fun decide(
        isRinging: Boolean,
        foreground: String?,
        foregroundClass: String?,
        ownPackage: String,
        nowElapsedMs: Long,
        lastRestoreElapsedMs: Long,
    ): Reentry {
        if (!isRinging) return Reentry.IGNORE
        if (foreground == null) return Reentry.IGNORE
        if (isRingScreen(foreground, foregroundClass, ownPackage)) return Reentry.IGNORE
        val since = nowElapsedMs - lastRestoreElapsedMs
        if (lastRestoreElapsedMs != 0L && since < DEBOUNCE_MS) return Reentry.DEFER
        return Reentry.RESTORE
    }

    /** True only for the ring screen and the PIN gate it opens — not for the rest of our package. */
    fun isRingScreen(foreground: String, foregroundClass: String?, ownPackage: String): Boolean {
        if (foreground != ownPackage) return false
        val classInOurPackage = foregroundClass?.startsWith("$ownPackage.") == true
        if (!classInOurPackage) return false
        val simple = foregroundClass.substringAfterLast('.')
        return RING_SCREEN_CLASSES.any { it == simple }
    }
}
