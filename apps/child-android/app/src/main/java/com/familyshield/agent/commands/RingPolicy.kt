package com.familyshield.agent.commands

/**
 * Plan 1.7 — the rules of the "ring" command, pure so they are JVM-tested: who may stop the ring,
 * how long it may run, and what the alarm stream is set to. The child must not be able to silence a
 * ring the parent started: Back, Home, the volume keys and the notification shade are not stop paths;
 * the parent's PIN on the ring screen, a parent command (`stop_ring` / `sos_clear`) and the cap are.
 */
object RingPolicy {
    enum class StopSource { PIN_VERIFIED, PARENT_COMMAND, TIMEOUT, CHILD_BACK, CHILD_VOLUME_KEY, SCREEN_OFF }

    /** Hard cap: a lost phone rings long enough to be found, not until the battery dies. */
    const val MAX_RING_MS: Long = 5 * 60 * 1000

    fun stopAllowed(source: StopSource): Boolean = when (source) {
        StopSource.PIN_VERIFIED, StopSource.PARENT_COMMAND, StopSource.TIMEOUT -> true
        StopSource.CHILD_BACK, StopSource.CHILD_VOLUME_KEY, StopSource.SCREEN_OFF -> false
    }

    /** The alarm stream is forced to its maximum for the ring and restored to [previous] afterwards. */
    fun ringVolume(maxVolume: Int): Int = maxVolume.coerceAtLeast(1)

    /** Restore only if nobody changed the stream meanwhile (the parent's max is not a value the child chose). */
    fun restoreVolume(previous: Int, current: Int, ringLevel: Int): Int = if (current == ringLevel) previous else current
}

/**
 * Plan 1.7 — which fix the `locate_now` answer carries. A fresh high-accuracy fix is requested with a
 * timeout; if it does not arrive, the last known fix is used only while it is still recent enough to
 * be a location rather than a memory.
 */
object LocatePolicy {
    /** How long the agent waits for a fresh high-accuracy fix before falling back. */
    const val FRESH_FIX_TIMEOUT_MS: Long = 30_000

    /** A cached fix older than this is not reported for locate_now (the parent asked where the phone *is*). */
    const val MAX_CACHED_AGE_MS: Long = 5 * 60 * 1000

    enum class Choice { FRESH, CACHED, NONE }

    fun choose(freshAvailable: Boolean, cachedTimeMs: Long?, nowMs: Long): Choice = when {
        freshAvailable -> Choice.FRESH
        cachedTimeMs != null && nowMs - cachedTimeMs <= MAX_CACHED_AGE_MS -> Choice.CACHED
        else -> Choice.NONE
    }
}
