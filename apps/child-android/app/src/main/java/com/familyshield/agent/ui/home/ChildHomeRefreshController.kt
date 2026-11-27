package com.familyshield.agent.ui.home

import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch

/**
 * Issue #1283 (Bug A): keeps the Child Home ("My day") copy fresh while the screen stays open
 * in the foreground via a ~60 s periodic tick plus a rules-changed listener, and cleanly tears
 * both down in `onPause()`.
 *
 * Extracted as a pure-JVM controller so both the periodic refresh and the `onPause()` teardown
 * are directly unit-testable without an Android Activity harness.
 */
class ChildHomeRefreshController(
    private val addRulesChangedListener: (() -> Unit) -> Unit,
    private val removeRulesChangedListener: (() -> Unit) -> Unit,
    private val onRefresh: () -> Unit,
    private val intervalMs: Long = REFRESH_INTERVAL_MS,
) {
    private var tickJob: Job? = null
    private var activeListener: (() -> Unit)? = null

    val isRunning: Boolean
        get() = activeListener != null || tickJob?.isActive == true

    fun start(scope: CoroutineScope) {
        stop()
        val listener: () -> Unit = { onRefresh() }
        activeListener = listener
        addRulesChangedListener(listener)
        tickJob = scope.launch {
            while (isActive) {
                delay(intervalMs)
                onRefresh()
            }
        }
    }

    fun stop() {
        tickJob?.cancel()
        tickJob = null
        activeListener?.let { removeRulesChangedListener(it) }
        activeListener = null
    }

    companion object {
        /** Foreground refresh cadence for Child Home (~60 s, #1283 Bug A). */
        const val REFRESH_INTERVAL_MS: Long = 60_000L
    }
}
