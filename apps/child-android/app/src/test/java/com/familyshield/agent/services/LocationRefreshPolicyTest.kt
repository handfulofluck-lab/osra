package com.familyshield.agent.services

import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test

/**
 * Issue #1053: pure-JVM unit tests for [LocationRefreshPolicy] and
 * [LocationRefreshWorker.acquirePeriodicFix], preventing 9-hour overnight location staleness while
 * avoiding background FGS starts, high-accuracy GPS battery drain, and duplicate/stale cache uploads.
 */
class LocationRefreshPolicyTest {

    private data class FakeFix(val id: String, val timeMs: Long)

    /**
     * Mutants killed:
     *  - raising `REFRESH_INTERVAL_HOURS` above `2L` or `FLEX_INTERVAL_MINUTES` above `30L`
     *    (allowing periodic refreshes to drift beyond the `<= 2.5-3 h` Doze target);
     *  - mis-sizing `FRESH_ENOUGH_MS`, `MAX_PERIODIC_CACHED_AGE_MS`, or `PERIODIC_FIX_TIMEOUT_MS`.
     */
    @Test
    fun `cadence, flex, freshness, cache cutoff, and timeout constants stay within 3h Doze budget`() {
        assertEquals(2L, LocationRefreshPolicy.REFRESH_INTERVAL_HOURS)
        assertEquals(30L, LocationRefreshPolicy.FLEX_INTERVAL_MINUTES)
        assertTrue("REFRESH_INTERVAL_HOURS must be <= 2h", LocationRefreshPolicy.REFRESH_INTERVAL_HOURS <= 2L)
        assertTrue("FLEX_INTERVAL_MINUTES must be <= 30m", LocationRefreshPolicy.FLEX_INTERVAL_MINUTES <= 30L)
        assertTrue(
            "Repeat interval plus flex window must stay <= 180 minutes",
            LocationRefreshPolicy.REFRESH_INTERVAL_HOURS * 60L + LocationRefreshPolicy.FLEX_INTERVAL_MINUTES <= 180L,
        )
        assertEquals(2L * 60L * 60L * 1000L, LocationRefreshPolicy.FRESH_ENOUGH_MS)
        assertEquals(30L * 60L * 1000L, LocationRefreshPolicy.MAX_PERIODIC_CACHED_AGE_MS)
        assertEquals(15_000L, LocationRefreshPolicy.PERIODIC_FIX_TIMEOUT_MS)
    }

    /**
     * Mutants killed:
     *  - dropping the `!isPaired` check (requesting location on an unlinked phone);
     *  - evaluating `consentPaused` or permissions before `isPaired`.
     */
    @Test
    fun `decide returns SKIP_UNPAIRED first when phone is not paired`() {
        assertEquals(
            LocationRefreshPolicy.Decision.SKIP_UNPAIRED,
            LocationRefreshPolicy.decide(
                isPaired = false,
                consentPaused = false,
                hasFine = true,
                hasCoarse = true,
                hasBackground = true,
                apiLevel = 34,
                lastUploadedAtMs = null,
                nowMs = 1_000_000L,
            ),
        )
        assertEquals(
            LocationRefreshPolicy.Decision.SKIP_UNPAIRED,
            LocationRefreshPolicy.decide(
                isPaired = false,
                consentPaused = true,
                hasFine = false,
                hasCoarse = false,
                hasBackground = false,
                apiLevel = 34,
                lastUploadedAtMs = null,
                nowMs = 1_000_000L,
            ),
        )
    }

    /**
     * Mutant killed: omitting `consentPaused` in `decide`, which would acquire location while
     * parental consent is withdrawn (ADR-0008 §3 violation).
     */
    @Test
    fun `decide returns SKIP_CONSENT_PAUSED when consent is withdrawn`() {
        assertEquals(
            LocationRefreshPolicy.Decision.SKIP_CONSENT_PAUSED,
            LocationRefreshPolicy.decide(
                isPaired = true,
                consentPaused = true,
                hasFine = true,
                hasCoarse = true,
                hasBackground = true,
                apiLevel = 34,
                lastUploadedAtMs = null,
                nowMs = 10_000_000L,
            ),
        )
    }

    /**
     * Mutants killed:
     *  - checking only fine/coarse without `LocationStartPolicy.shouldStart` (allowing background
     *    collection on API 29+ without `ACCESS_BACKGROUND_LOCATION`);
     *  - requiring `ACCESS_BACKGROUND_LOCATION` on API 28 where the runtime permission does not exist;
     *  - requiring `ACCESS_FINE_LOCATION` when coarse location + background location are granted.
     */
    @Test
    fun `decide enforces API 28 vs API 29 plus background location rule via LocationStartPolicy`() {
        val now = 50_000_000L

        // Neither fine nor coarse -> SKIP_NO_PERMISSION on every API level.
        assertEquals(
            LocationRefreshPolicy.Decision.SKIP_NO_PERMISSION,
            LocationRefreshPolicy.decide(
                isPaired = true,
                consentPaused = false,
                hasFine = false,
                hasCoarse = false,
                hasBackground = true,
                apiLevel = 28,
                lastUploadedAtMs = null,
                nowMs = now,
            ),
        )

        // API 28: fine or coarse without ACCESS_BACKGROUND_LOCATION -> FETCH.
        assertEquals(
            LocationRefreshPolicy.Decision.FETCH,
            LocationRefreshPolicy.decide(
                isPaired = true,
                consentPaused = false,
                hasFine = true,
                hasCoarse = false,
                hasBackground = false,
                apiLevel = 28,
                lastUploadedAtMs = null,
                nowMs = now,
            ),
        )

        // API 29 and API 34: fine + coarse WITHOUT ACCESS_BACKGROUND_LOCATION -> SKIP_NO_PERMISSION.
        assertEquals(
            LocationRefreshPolicy.Decision.SKIP_NO_PERMISSION,
            LocationRefreshPolicy.decide(
                isPaired = true,
                consentPaused = false,
                hasFine = true,
                hasCoarse = true,
                hasBackground = false,
                apiLevel = 29,
                lastUploadedAtMs = null,
                nowMs = now,
            ),
        )
        assertEquals(
            LocationRefreshPolicy.Decision.SKIP_NO_PERMISSION,
            LocationRefreshPolicy.decide(
                isPaired = true,
                consentPaused = false,
                hasFine = true,
                hasCoarse = true,
                hasBackground = false,
                apiLevel = 34,
                lastUploadedAtMs = null,
                nowMs = now,
            ),
        )

        // API 29+: coarse (or fine) WITH ACCESS_BACKGROUND_LOCATION -> FETCH.
        assertEquals(
            LocationRefreshPolicy.Decision.FETCH,
            LocationRefreshPolicy.decide(
                isPaired = true,
                consentPaused = false,
                hasFine = false,
                hasCoarse = true,
                hasBackground = true,
                apiLevel = 29,
                lastUploadedAtMs = null,
                nowMs = now,
            ),
        )
    }

    /**
     * Mutants killed:
     *  - ignoring `lastUploadedAtMs` (waking location hardware every 2h even when `LocationService`
     *    uploaded 5 minutes ago);
     *  - using `<= FRESH_ENOUGH_MS` instead of `< FRESH_ENOUGH_MS` (causing an exact 2-hour periodic
     *    tick to skip itself and double the gap to 4 hours).
     */
    @Test
    fun `decide skips recent uploads below 2h and fetches at or beyond 2h`() {
        val now = 20_000_000L

        // Never uploaded -> FETCH.
        assertEquals(
            LocationRefreshPolicy.Decision.FETCH,
            LocationRefreshPolicy.decide(
                isPaired = true,
                consentPaused = false,
                hasFine = true,
                hasCoarse = true,
                hasBackground = true,
                apiLevel = 34,
                lastUploadedAtMs = null,
                nowMs = now,
            ),
        )

        // Uploaded right now (age 0) -> SKIP_RECENT.
        assertEquals(
            LocationRefreshPolicy.Decision.SKIP_RECENT,
            LocationRefreshPolicy.decide(
                isPaired = true,
                consentPaused = false,
                hasFine = true,
                hasCoarse = true,
                hasBackground = true,
                apiLevel = 34,
                lastUploadedAtMs = now,
                nowMs = now,
            ),
        )

        // Uploaded 2h - 1ms ago -> SKIP_RECENT.
        assertEquals(
            LocationRefreshPolicy.Decision.SKIP_RECENT,
            LocationRefreshPolicy.decide(
                isPaired = true,
                consentPaused = false,
                hasFine = true,
                hasCoarse = true,
                hasBackground = true,
                apiLevel = 34,
                lastUploadedAtMs = now - LocationRefreshPolicy.FRESH_ENOUGH_MS + 1L,
                nowMs = now,
            ),
        )

        // Uploaded exactly 2h ago -> FETCH (periodic tick on schedule must NOT skip itself).
        assertEquals(
            LocationRefreshPolicy.Decision.FETCH,
            LocationRefreshPolicy.decide(
                isPaired = true,
                consentPaused = false,
                hasFine = true,
                hasCoarse = true,
                hasBackground = true,
                apiLevel = 34,
                lastUploadedAtMs = now - LocationRefreshPolicy.FRESH_ENOUGH_MS,
                nowMs = now,
            ),
        )

        // Uploaded 9h ago overnight -> FETCH.
        assertEquals(
            LocationRefreshPolicy.Decision.FETCH,
            LocationRefreshPolicy.decide(
                isPaired = true,
                consentPaused = false,
                hasFine = true,
                hasCoarse = true,
                hasBackground = true,
                apiLevel = 34,
                lastUploadedAtMs = now - 9L * 60L * 60L * 1000L,
                nowMs = now,
            ),
        )
    }

    /**
     * Mutant killed: writing `nowMs - lastUploadedAtMs < FRESH_ENOUGH_MS` without checking
     * `nowMs >= lastUploadedAtMs`, which turns a negative delta after a backward clock jump into
     * `SKIP_RECENT` and freezes refreshes until wall-clock time catches back up.
     */
    @Test
    fun `decide returns FETCH when wall clock jumps backwards behind lastUploadedAtMs`() {
        val lastUploaded = 50_000_000L
        val rolledBackNow = lastUploaded - 6L * 60L * 60L * 1000L

        assertEquals(
            LocationRefreshPolicy.Decision.FETCH,
            LocationRefreshPolicy.decide(
                isPaired = true,
                consentPaused = false,
                hasFine = true,
                hasCoarse = true,
                hasBackground = true,
                apiLevel = 34,
                lastUploadedAtMs = lastUploaded,
                nowMs = rolledBackNow,
            ),
        )
        assertEquals(
            LocationRefreshPolicy.Decision.FETCH,
            LocationRefreshPolicy.decide(
                isPaired = true,
                consentPaused = false,
                hasFine = true,
                hasCoarse = true,
                hasBackground = true,
                apiLevel = 34,
                lastUploadedAtMs = lastUploaded,
                nowMs = lastUploaded - 1L,
            ),
        )
    }

    /**
     * Mutants killed:
     *  - preferring `CACHED` over `FRESH` when both exist;
     *  - omitting `MAX_PERIODIC_CACHED_AGE_MS` (re-uploading a 9-hour-old overnight `lastLocation`!);
     *  - changing `<= MAX_PERIODIC_CACHED_AGE_MS` to `<` on the 30-minute boundary;
     *  - omitting `cachedTimeMs > lastUploadedAtMs` (re-uploading a cached fix already on the server).
     */
    @Test
    fun `choosePeriodicFix prefers fresh, accepts recent un-uploaded cache, and rejects stale 9h or already-uploaded cache`() {
        val now = 100_000_000L
        val nineHoursMs = 9L * 60L * 60L * 1000L

        // Fresh available always wins.
        assertEquals(
            LocationRefreshPolicy.Choice.FRESH,
            LocationRefreshPolicy.choosePeriodicFix(
                freshAvailable = true,
                cachedTimeMs = now - 60_000L,
                lastUploadedAtMs = null,
                nowMs = now,
            ),
        )

        // Fresh missing, cached <= 30m old, never uploaded before -> CACHED.
        assertEquals(
            LocationRefreshPolicy.Choice.CACHED,
            LocationRefreshPolicy.choosePeriodicFix(
                freshAvailable = false,
                cachedTimeMs = now - LocationRefreshPolicy.MAX_PERIODIC_CACHED_AGE_MS,
                lastUploadedAtMs = null,
                nowMs = now,
            ),
        )

        // Fresh missing, cached 15m old AND newer than lastUploadedAtMs (2h10m ago) -> CACHED.
        assertEquals(
            LocationRefreshPolicy.Choice.CACHED,
            LocationRefreshPolicy.choosePeriodicFix(
                freshAvailable = false,
                cachedTimeMs = now - 15L * 60L * 1000L,
                lastUploadedAtMs = now - 130L * 60L * 1000L,
                nowMs = now,
            ),
        )

        // Stale 9h cached fix -> NONE (never re-uploaded as if current!).
        assertEquals(
            LocationRefreshPolicy.Choice.NONE,
            LocationRefreshPolicy.choosePeriodicFix(
                freshAvailable = false,
                cachedTimeMs = now - nineHoursMs,
                lastUploadedAtMs = null,
                nowMs = now,
            ),
        )

        // Cached 30m + 1ms old -> NONE.
        assertEquals(
            LocationRefreshPolicy.Choice.NONE,
            LocationRefreshPolicy.choosePeriodicFix(
                freshAvailable = false,
                cachedTimeMs = now - LocationRefreshPolicy.MAX_PERIODIC_CACHED_AGE_MS - 1L,
                lastUploadedAtMs = null,
                nowMs = now,
            ),
        )

        // Cached 10m old, but equal to or older than lastUploadedAtMs -> NONE (already uploaded!).
        val recentCached = now - 10L * 60L * 1000L
        assertEquals(
            LocationRefreshPolicy.Choice.NONE,
            LocationRefreshPolicy.choosePeriodicFix(
                freshAvailable = false,
                cachedTimeMs = recentCached,
                lastUploadedAtMs = recentCached,
                nowMs = now,
            ),
        )
        assertEquals(
            LocationRefreshPolicy.Choice.NONE,
            LocationRefreshPolicy.choosePeriodicFix(
                freshAvailable = false,
                cachedTimeMs = recentCached,
                lastUploadedAtMs = recentCached + 5_000L,
                nowMs = now,
            ),
        )

        // Null cached fix -> NONE.
        assertEquals(
            LocationRefreshPolicy.Choice.NONE,
            LocationRefreshPolicy.choosePeriodicFix(
                freshAvailable = false,
                cachedTimeMs = null,
                lastUploadedAtMs = null,
                nowMs = now,
            ),
        )
    }

    /**
     * Mutants killed:
     *  - letting an out-of-order offline Room flush overwrite a newer `lastLocationUploadedAtMs`
     *    with an older timestamp;
     *  - refusing to overwrite a future-dated `previousMs` (`> nowMs`) after a backward clock jump.
     */
    @Test
    fun `mergedLastUploadedAtMs advances monotonically under normal clock and heals backward clock jumps`() {
        val now = 50_000_000L
        assertEquals(now, LocationRefreshPolicy.mergedLastUploadedAtMs(previousMs = null, uploadedPingTimeMs = now, nowMs = now))
        assertEquals(
            now,
            LocationRefreshPolicy.mergedLastUploadedAtMs(previousMs = now - 60_000L, uploadedPingTimeMs = now, nowMs = now),
        )
        // Older offline Room batch flushing after a newer live upload must NOT roll the watermark back.
        assertEquals(
            now - 10_000L,
            LocationRefreshPolicy.mergedLastUploadedAtMs(
                previousMs = now - 10_000L,
                uploadedPingTimeMs = now - 9L * 60L * 60L * 1000L,
                nowMs = now,
            ),
        )
        // Future-dated previousMs from before a backward clock jump MUST be overwritten so 2h cadence heals.
        assertEquals(
            now,
            LocationRefreshPolicy.mergedLastUploadedAtMs(
                previousMs = now + 5L * 60L * 60L * 1000L,
                uploadedPingTimeMs = now,
                nowMs = now,
            ),
        )
    }

    /**
     * Mutants killed:
     *  - passing the wrong timeout instead of `PERIODIC_FIX_TIMEOUT_MS` (15 s);
     *  - querying `lastLocation` unnecessarily when the balanced fix already succeeded;
     *  - swallowing `CancellationException` inside `acquirePeriodicFix`.
     */
    @Test
    fun `acquirePeriodicFix bounds balanced request to 15s, gates lastLocation fallback, and preserves cancellation`() = runBlocking {
        val now = 80_000_000L
        val timeouts = mutableListOf<Long>()
        var lastLocationCalls = 0
        val freshFix = FakeFix("balanced", now)

        val gotFresh = LocationRefreshWorker.acquirePeriodicFix(
            fetchBalanced = { freshFix },
            fetchLastLocation = { lastLocationCalls += 1; FakeFix("cached", now) },
            timeOf = { it.timeMs },
            lastUploadedAtMs = now - LocationRefreshPolicy.FRESH_ENOUGH_MS,
            nowMs = { now },
            withTimeout = { timeoutMs, block ->
                timeouts += timeoutMs
                block()
            },
        )
        assertEquals(LocationRefreshPolicy.Choice.FRESH, gotFresh.choice)
        assertEquals(freshFix, gotFresh.location)
        assertEquals(listOf(LocationRefreshPolicy.PERIODIC_FIX_TIMEOUT_MS), timeouts)
        assertEquals(0, lastLocationCalls)

        // Balanced timeout + 9h-old cached fix -> NONE (null location).
        val stale9h = FakeFix("stale9h", now - 9L * 60L * 60L * 1000L)
        val rejectedStale = LocationRefreshWorker.acquirePeriodicFix(
            fetchBalanced = { null },
            fetchLastLocation = { stale9h },
            timeOf = { it.timeMs },
            lastUploadedAtMs = null,
            nowMs = { now },
            withTimeout = { _, block -> block() },
        )
        assertEquals(LocationRefreshPolicy.Choice.NONE, rejectedStale.choice)
        assertNull(rejectedStale.location)

        // Balanced failure + recent un-uploaded cached fix -> CACHED.
        val recentUnuploaded = FakeFix("recent12m", now - 12L * 60L * 1000L)
        val acceptedCached = LocationRefreshWorker.acquirePeriodicFix(
            fetchBalanced = { throw IllegalStateException("provider busy") },
            fetchLastLocation = { recentUnuploaded },
            timeOf = { it.timeMs },
            lastUploadedAtMs = now - 3L * 60L * 60L * 1000L,
            nowMs = { now },
            withTimeout = { _, block -> block() },
        )
        assertEquals(LocationRefreshPolicy.Choice.CACHED, acceptedCached.choice)
        assertEquals(recentUnuploaded, acceptedCached.location)

        // Coroutine cancellation must propagate, never convert into NONE.
        try {
            LocationRefreshWorker.acquirePeriodicFix<FakeFix>(
                fetchBalanced = { throw CancellationException("worker stopped") },
                fetchLastLocation = { null },
                timeOf = { it.timeMs },
                lastUploadedAtMs = null,
                nowMs = { now },
                withTimeout = { _, block -> block() },
            )
            fail("Expected CancellationException to propagate")
        } catch (_: CancellationException) {
            // expected
        }
    }
}
