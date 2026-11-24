package com.familyshield.agent.services

/**
 * Issue #1053: pure policy for the periodic Doze-resilient child location refresh.
 *
 * When a child phone sits locked and stationary overnight, `LocationService` may be stopped by the OS
 * (or never started if background FGS start was refused), leaving the parent's map 9+ hours stale by
 * morning. [LocationRefreshWorker] runs every [REFRESH_INTERVAL_HOURS] (with [FLEX_INTERVAL_MINUTES]
 * flex, keeping spacing `<= 2.5-3 h` across Doze maintenance windows) and consults this policy before
 * touching Play Services or the network:
 *  - skips when unpaired, when consent is paused (ADR-0008 §3), or when background location permission
 *    is missing ([LocationStartPolicy.shouldStart]);
 *  - skips when a location ping was already uploaded within [FRESH_ENOUGH_MS] (unless the device clock
 *    jumped backwards, `nowMs < lastUploadedAtMs`, which triggers [Decision.FETCH] so refreshes cannot
 *    freeze);
 *  - requests at most one balanced-power fix bounded by [PERIODIC_FIX_TIMEOUT_MS], falling back to
 *    `lastLocation` only when it is at most [MAX_PERIODIC_CACHED_AGE_MS] old **and** strictly newer
 *    than [lastUploadedAtMs], so a stale 9-hour cached fix or an already-uploaded fix is never re-sent.
 */
object LocationRefreshPolicy {

    /** WorkManager repeat interval: 2 hours. */
    const val REFRESH_INTERVAL_HOURS: Long = 2L

    /** WorkManager trailing flex window: 30 minutes (runs in `[90 min, 120 min]`, `<= 2.5-3 h` under Doze). */
    const val FLEX_INTERVAL_MINUTES: Long = 30L

    /** Skip periodic acquisition when a fix newer than 2 hours is already on the server. */
    const val FRESH_ENOUGH_MS: Long = 2L * 60L * 60L * 1000L

    /** Maximum age of `lastLocation` accepted as a fallback when balanced fresh acquisition times out. */
    const val MAX_PERIODIC_CACHED_AGE_MS: Long = 30L * 60L * 1000L

    /** Single balanced-power fix timeout (never high-accuracy GPS in periodic background work). */
    const val PERIODIC_FIX_TIMEOUT_MS: Long = 15_000L

    enum class Decision {
        SKIP_UNPAIRED,
        SKIP_CONSENT_PAUSED,
        SKIP_NO_PERMISSION,
        SKIP_RECENT,
        FETCH,
    }

    enum class Choice {
        FRESH,
        CACHED,
        NONE,
    }

    /**
     * Decides whether the periodic worker should request a location fix now.
     *
     * Reuses [LocationStartPolicy.shouldStart] so Android 10+ (API 29+) requires
     * `ACCESS_BACKGROUND_LOCATION` alongside fine or coarse location. If `nowMs < lastUploadedAtMs`
     * (wall clock rolled backwards), returns [Decision.FETCH] rather than treating a negative delta as
     * recent, so a clock jump never freezes periodic refreshes.
     */
    fun decide(
        isPaired: Boolean,
        consentPaused: Boolean,
        hasFine: Boolean,
        hasCoarse: Boolean,
        hasBackground: Boolean,
        apiLevel: Int,
        lastUploadedAtMs: Long?,
        nowMs: Long,
    ): Decision {
        if (!isPaired) return Decision.SKIP_UNPAIRED
        if (consentPaused) return Decision.SKIP_CONSENT_PAUSED
        if (!LocationStartPolicy.shouldStart(
                isPaired = isPaired,
                hasFineLocation = hasFine,
                hasCoarseLocation = hasCoarse,
                hasBackgroundLocation = hasBackground,
                apiLevel = apiLevel,
            )
        ) {
            return Decision.SKIP_NO_PERMISSION
        }
        if (lastUploadedAtMs != null &&
            nowMs >= lastUploadedAtMs &&
            (nowMs - lastUploadedAtMs) in 0L until FRESH_ENOUGH_MS
        ) {
            return Decision.SKIP_RECENT
        }
        return Decision.FETCH
    }

    /**
     * Chooses which fix (if any) a periodic refresh may upload.
     *
     * Prefers [Choice.FRESH]; accepts [Choice.CACHED] only when [cachedTimeMs] is within
     * [MAX_PERIODIC_CACHED_AGE_MS] of [nowMs] **and** strictly newer than [lastUploadedAtMs] (when one
     * exists), preventing both 9-hour stale cache re-uploads and duplicate uploads of the same point.
     */
    fun choosePeriodicFix(
        freshAvailable: Boolean,
        cachedTimeMs: Long?,
        lastUploadedAtMs: Long?,
        nowMs: Long,
    ): Choice = when {
        freshAvailable -> Choice.FRESH
        cachedTimeMs != null &&
            nowMs - cachedTimeMs <= MAX_PERIODIC_CACHED_AGE_MS &&
            (lastUploadedAtMs == null || cachedTimeMs > lastUploadedAtMs) -> Choice.CACHED
        else -> Choice.NONE
    }

    /**
     * Computes the persisted `lastLocationUploadedAtMs` watermark after a 2xx ping upload.
     *
     * Preserves a newer valid [previousMs] (`<= nowMs`) when an older offline Room batch flushes out of
     * order, while overwriting a future-dated [previousMs] (`> nowMs`) after a backward clock jump so
     * normal 2-hour spacing resumes immediately.
     */
    fun mergedLastUploadedAtMs(
        previousMs: Long?,
        uploadedPingTimeMs: Long,
        nowMs: Long,
    ): Long {
        if (previousMs != null && previousMs <= nowMs && previousMs > uploadedPingTimeMs) {
            return previousMs
        }
        return uploadedPingTimeMs
    }
}
