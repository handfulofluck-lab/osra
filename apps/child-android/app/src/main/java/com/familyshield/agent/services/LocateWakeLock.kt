package com.familyshield.agent.services

import android.content.Context
import android.os.PowerManager
import android.util.Log
import com.familyshield.agent.commands.LocatePolicy

/**
 * Pure-JVM reference-counted wake-lock tracker so overlapping `locate_now` calls never drop each
 * other's wake lock early and never under-lock on extra releases.
 */
internal class LocateWakeLockTracker(
    private val timeoutMs: Long = LocatePolicy.WAKE_LOCK_TIMEOUT_MS,
    private val acquireOsLock: (Long) -> Unit,
    private val releaseOsLock: () -> Unit,
) {
    private var activeCount: Int = 0

    @Synchronized
    fun acquire(): Boolean {
        activeCount += 1
        return try {
            acquireOsLock(timeoutMs)
            true
        } catch (_: Exception) {
            activeCount = (activeCount - 1).coerceAtLeast(0)
            false
        }
    }

    @Synchronized
    fun release() {
        if (activeCount <= 0) return
        activeCount -= 1
        if (activeCount == 0) {
            runCatching { releaseOsLock() }
        }
    }

    @Synchronized
    fun activeCount(): Int = activeCount
}

/**
 * Issue #1054: bounded [PowerManager.PARTIAL_WAKE_LOCK] handoff across `CommandDispatcher.locateNow`
 * -> `LocationService.locateNowOnce` (or direct background fallback).
 *
 * Uses a non-reference-counted Android `WakeLock` (`setReferenceCounted(false)`) paired with
 * [LocateWakeLockTracker] so each overlapping acquire re-arms the [LocatePolicy.WAKE_LOCK_TIMEOUT_MS]
 * (45 s) safety timeout, overlapping completions never release early, and an OS-expired timeout can
 * never throw `WakeLock under-locked` on release.
 */
object LocateWakeLock {
    private const val TAG = "LocateWakeLock"
    private const val WAKE_LOCK_TAG = "osra:locate_now"

    private val lock = Any()
    private var wakeLock: PowerManager.WakeLock? = null
    private var tracker: LocateWakeLockTracker? = null

    fun acquire(context: Context): Boolean = synchronized(lock) {
        val currentTracker = tracker ?: createTracker(context.applicationContext) ?: return false
        currentTracker.acquire()
    }

    fun release() = synchronized(lock) {
        tracker?.release()
    }

    private fun createTracker(appContext: Context): LocateWakeLockTracker? {
        val pm = appContext.getSystemService(PowerManager::class.java) ?: return null
        val wl = runCatching {
            pm.newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, WAKE_LOCK_TAG).apply {
                setReferenceCounted(false)
            }
        }.onFailure {
            Log.w(TAG, "Unable to create PARTIAL_WAKE_LOCK for locate_now", it)
        }.getOrNull() ?: return null
        wakeLock = wl
        return LocateWakeLockTracker(
            timeoutMs = LocatePolicy.WAKE_LOCK_TIMEOUT_MS,
            acquireOsLock = { timeout -> wl.acquire(timeout) },
            releaseOsLock = { if (wl.isHeld) wl.release() },
        ).also { tracker = it }
    }
}
