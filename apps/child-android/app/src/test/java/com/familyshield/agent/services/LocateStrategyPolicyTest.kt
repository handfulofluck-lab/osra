package com.familyshield.agent.services

import com.familyshield.agent.commands.LocateFix
import com.familyshield.agent.commands.LocatePolicy
import com.familyshield.agent.push.PushTokenHydrator
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Issue #1054: pure-JVM policy and seam tests for reaching a locked/dozing child phone on
 * `locate_now`: two-stage fresh-fix acquisition, timeout budget invariants, cached-fix staleness
 * cutoff, reference-counted bounded wake-lock tracking, and FCM-free-safe token hydration.
 */
class LocateStrategyPolicyTest {

    private data class FakeFix(val label: String, val timeMs: Long)

    /**
     * Mutant killed: shrinking `WAKE_LOCK_TIMEOUT_MS` to `<= FRESH_FIX_TIMEOUT_MS`, or raising
     * `HIGH_ACCURACY_TIMEOUT_MS + BALANCED_FALLBACK_TIMEOUT_MS` above `FRESH_FIX_TIMEOUT_MS` —
     * either lets Doze kill the CPU before acquisition+upload finish or blows the 30 s budget.
     */
    @Test
    fun `timeout invariants keep two-stage budget within fresh budget and below wake-lock cap`() {
        assertEquals(15_000L, LocatePolicy.HIGH_ACCURACY_TIMEOUT_MS)
        assertEquals(10_000L, LocatePolicy.BALANCED_FALLBACK_TIMEOUT_MS)
        assertEquals(30_000L, LocatePolicy.FRESH_FIX_TIMEOUT_MS)
        assertEquals(45_000L, LocatePolicy.WAKE_LOCK_TIMEOUT_MS)
        assertTrue(
            "Stage 1 + Stage 2 must fit inside FRESH_FIX_TIMEOUT_MS",
            LocatePolicy.HIGH_ACCURACY_TIMEOUT_MS + LocatePolicy.BALANCED_FALLBACK_TIMEOUT_MS <= LocatePolicy.FRESH_FIX_TIMEOUT_MS,
        )
        assertTrue(
            "Wake-lock safety timeout must strictly exceed FRESH_FIX_TIMEOUT_MS to cover upload",
            LocatePolicy.FRESH_FIX_TIMEOUT_MS < LocatePolicy.WAKE_LOCK_TIMEOUT_MS,
        )
    }

    /**
     * Mutant killed: invoking Stage 2 or `lastLocation` unconditionally when Stage 1 already
     * returned a fix, or passing `FRESH_FIX_TIMEOUT_MS` (30 s) instead of `HIGH_ACCURACY_TIMEOUT_MS`
     * (15 s) to Stage 1.
     */
    @Test
    fun `stage 1 high-accuracy fix succeeds without invoking balanced or cached fallbacks`() = runBlocking {
        val timeouts = mutableListOf<Long>()
        var balancedCalls = 0
        var lastLocationCalls = 0
        val now = 1_000_000L
        val gpsFix = FakeFix("gps", now)

        val result = LocationFixFetcher.acquireFix(
            fetchHighAccuracy = { gpsFix },
            fetchBalanced = { balancedCalls += 1; FakeFix("net", now) },
            fetchLastLocation = { lastLocationCalls += 1; FakeFix("cached", now) },
            timeOf = { it.timeMs },
            nowMs = { now },
            withTimeout = { timeoutMs, block ->
                timeouts += timeoutMs
                block()
            },
        )

        assertEquals(LocatePolicy.Choice.FRESH, result.choice)
        assertEquals(LocateFix.FRESH, result.fix)
        assertEquals(gpsFix, result.location)
        assertEquals(listOf(LocatePolicy.HIGH_ACCURACY_TIMEOUT_MS), timeouts)
        assertEquals(0, balancedCalls)
        assertEquals(0, lastLocationCalls)
    }

    /**
     * Mutant killed: dropping Stage 2 (`PRIORITY_BALANCED_POWER_ACCURACY`) so a GPS miss on an
     * indoor/locked phone jumps straight to `lastLocation` (or returns NONE).
     */
    @Test
    fun `stage 1 null or timeout falls back to stage 2 balanced power accuracy`() = runBlocking {
        val timeouts = mutableListOf<Long>()
        var lastLocationCalls = 0
        val now = 1_000_000L
        val netFix = FakeFix("balanced", now)

        val result = LocationFixFetcher.acquireFix(
            fetchHighAccuracy = { null },
            fetchBalanced = { netFix },
            fetchLastLocation = { lastLocationCalls += 1; FakeFix("cached", now - 60_000L) },
            timeOf = { it.timeMs },
            nowMs = { now },
            withTimeout = { timeoutMs, block ->
                timeouts += timeoutMs
                block()
            },
        )

        assertEquals(LocatePolicy.Choice.FRESH, result.choice)
        assertEquals(LocateFix.FRESH, result.fix)
        assertEquals(netFix, result.location)
        assertEquals(
            listOf(LocatePolicy.HIGH_ACCURACY_TIMEOUT_MS, LocatePolicy.BALANCED_FALLBACK_TIMEOUT_MS),
            timeouts,
        )
        assertEquals(0, lastLocationCalls)
    }

    /**
     * Mutant killed: letting an exception from Stage 1 abort `acquireFix` instead of trying Stage 2.
     */
    @Test
    fun `stage 1 failure still falls back to stage 2 balanced power accuracy`() = runBlocking {
        val now = 1_000_000L
        val netFix = FakeFix("balanced", now)

        val result = LocationFixFetcher.acquireFix(
            fetchHighAccuracy = { throw IllegalStateException("gnss unavailable") },
            fetchBalanced = { netFix },
            fetchLastLocation = { null },
            timeOf = { it.timeMs },
            nowMs = { now },
            withTimeout = { _, block -> block() },
        )

        assertEquals(LocatePolicy.Choice.FRESH, result.choice)
        assertEquals(LocateFix.FRESH, result.fix)
        assertEquals(netFix, result.location)
    }

    /**
     * Mutant killed: changing `<=` to `<` on `MAX_CACHED_AGE_MS` or omitting Stage 3 `lastLocation`
     * fallback when both fresh stages return null.
     */
    @Test
    fun `both fresh stages missing falls back to recent cached fix up to five minutes old`() = runBlocking {
        val now = 1_000_000L
        val boundaryFix = FakeFix("cached-boundary", now - LocatePolicy.MAX_CACHED_AGE_MS)

        val result = LocationFixFetcher.acquireFix(
            fetchHighAccuracy = { null },
            fetchBalanced = { null },
            fetchLastLocation = { boundaryFix },
            timeOf = { it.timeMs },
            nowMs = { now },
            withTimeout = { _, block -> block() },
        )

        assertEquals(LocatePolicy.Choice.CACHED, result.choice)
        assertEquals(LocateFix.CACHED, result.fix)
        assertEquals(boundaryFix, result.location)
    }

    /**
     * Mutant killed: removing the 5-minute `MAX_CACHED_AGE_MS` cutoff so a stale location from
     * hours ago is reported as current.
     */
    @Test
    fun `cached fix older than five minutes or absent returns NONE`() = runBlocking {
        val now = 1_000_000L
        val staleFix = FakeFix("stale", now - LocatePolicy.MAX_CACHED_AGE_MS - 1L)

        val staleResult = LocationFixFetcher.acquireFix(
            fetchHighAccuracy = { null },
            fetchBalanced = { null },
            fetchLastLocation = { staleFix },
            timeOf = { it.timeMs },
            nowMs = { now },
            withTimeout = { _, block -> block() },
        )
        assertEquals(LocatePolicy.Choice.NONE, staleResult.choice)
        assertNull(staleResult.fix)
        assertNull(staleResult.location)

        val nullResult = LocationFixFetcher.acquireFix<FakeFix>(
            fetchHighAccuracy = { null },
            fetchBalanced = { null },
            fetchLastLocation = { null },
            timeOf = { it.timeMs },
            nowMs = { now },
            withTimeout = { _, block -> block() },
        )
        assertEquals(LocatePolicy.Choice.NONE, nullResult.choice)
        assertNull(nullResult.fix)
        assertNull(nullResult.location)
    }

    /**
     * Mutant killed: dropping reference counting in `LocateWakeLockTracker` (releasing the OS wake
     * lock on the first `release()` while a second overlapping `locate_now` is still running) or
     * acquiring without `LocatePolicy.WAKE_LOCK_TIMEOUT_MS`.
     */
    @Test
    fun `wake lock tracker bounds timeout, preserves overlapping holds, and ignores extra releases`() {
        val acquires = mutableListOf<Long>()
        var releases = 0
        val tracker = LocateWakeLockTracker(
            acquireOsLock = { acquires += it },
            releaseOsLock = { releases += 1 },
        )

        assertTrue(tracker.acquire())
        assertTrue(tracker.acquire())
        assertEquals(listOf(LocatePolicy.WAKE_LOCK_TIMEOUT_MS, LocatePolicy.WAKE_LOCK_TIMEOUT_MS), acquires)
        assertEquals(2, tracker.activeCount())
        assertEquals(0, releases)

        // First overlapping locate finishes: wake lock must stay held for the second.
        tracker.release()
        assertEquals(1, tracker.activeCount())
        assertEquals(0, releases)

        // Second finishes: now the OS wake lock is released.
        tracker.release()
        assertEquals(0, tracker.activeCount())
        assertEquals(1, releases)

        // Extra release (e.g. non-wake-locked caller or double cleanup) must not under-lock.
        tracker.release()
        assertEquals(0, tracker.activeCount())
        assertEquals(1, releases)
    }

    /**
     * Mutant killed: leaving `activeCount` incremented when the OS `acquire` throws, which would
     * leak the count and prevent subsequent releases from dropping the lock.
     */
    @Test
    fun `wake lock tracker rolls back count if OS acquire throws`() {
        var releases = 0
        val tracker = LocateWakeLockTracker(
            acquireOsLock = { throw SecurityException("no WAKE_LOCK") },
            releaseOsLock = { releases += 1 },
        )

        assertFalse(tracker.acquire())
        assertEquals(0, tracker.activeCount())
        tracker.release()
        assertEquals(0, releases)
    }

    /**
     * Mutant killed: calling `fetchToken()` unconditionally even when DataStore already holds a
     * non-blank push token, adding Play Services IPC overhead to every poll.
     */
    @Test
    fun `push token hydrator skips Firebase when a non-blank token is already stored`() = runBlocking {
        var fetches = 0
        var saves = 0

        val token = PushTokenHydrator.hydrateIfMissing(
            readStored = { "stored-fcm-token" },
            saveToken = { saves += 1 },
            fetchToken = { fetches += 1; "new-token" },
        )

        assertEquals("stored-fcm-token", token)
        assertEquals(0, fetches)
        assertEquals(0, saves)
    }

    /**
     * Mutant killed: returning the hydrated token without persisting it to DataStore via
     * `saveToken`, so subsequent polls would re-fetch or lose it.
     */
    @Test
    fun `push token hydrator fetches and persists token when stored token is missing or blank`() = runBlocking {
        val saved = mutableListOf<String>()

        val hydratedFromNull = PushTokenHydrator.hydrateIfMissing(
            readStored = { null },
            saveToken = { saved += it },
            fetchToken = { "hydrated-fcm-token-1" },
        )
        assertEquals("hydrated-fcm-token-1", hydratedFromNull)
        assertEquals(listOf("hydrated-fcm-token-1"), saved)

        val hydratedFromBlank = PushTokenHydrator.hydrateIfMissing(
            readStored = { "   " },
            saveToken = { saved += it },
            fetchToken = { "hydrated-fcm-token-2" },
        )
        assertEquals("hydrated-fcm-token-2", hydratedFromBlank)
        assertEquals(listOf("hydrated-fcm-token-1", "hydrated-fcm-token-2"), saved)
    }

    /**
     * Mutant killed: dropping the `try/catch` around Firebase hydration so FCM-free builds (where
     * `google-services.json` is absent and `FirebaseApp` is uninitialized) crash at startup or poll.
     */
    @Test
    fun `push token hydrator returns null without throwing when FirebaseApp is uninitialized`() = runBlocking {
        var saves = 0

        val token = PushTokenHydrator.hydrateIfMissing(
            readStored = { null },
            saveToken = { saves += 1 },
            fetchToken = { throw IllegalStateException("Default FirebaseApp is not initialized") },
        )

        assertNull(token)
        assertEquals(0, saves)
    }

    /**
     * Mutant killed: persisting a blank token returned by Play Services into DataStore.
     */
    @Test
    fun `push token hydrator ignores blank fetched tokens`() = runBlocking {
        var saves = 0

        val token = PushTokenHydrator.hydrateIfMissing(
            readStored = { null },
            saveToken = { saves += 1 },
            fetchToken = { "   " },
        )

        assertNull(token)
        assertEquals(0, saves)
    }
}
