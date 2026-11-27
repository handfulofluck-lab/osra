package com.familyshield.agent.ui.home

import java.io.File
import java.util.concurrent.CopyOnWriteArrayList
import java.util.concurrent.atomic.AtomicInteger
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Issue #1283 (Bug A): verifies that [ChildHomeRefreshController] refreshes Child Home on both
 * the periodic foreground tick and incoming rule changes, and stops both on `stop()` (`onPause`).
 */
class ChildHomeRefreshControllerTest {

    @Test
    fun `start registers rules listener and refreshes on rule change and periodic ticks, stop tears both down (#1283)`() {
        // Mutant 1: omitting `addRulesChangedListener(listener)` makes `refreshes` stay 0 when a rule arrives.
        // Mutant 2: omitting the periodic `delay(intervalMs)` loop makes tick refreshes stay 0.
        // Mutant 3: omitting `tickJob?.cancel()` or `removeRulesChangedListener` in `stop()` leaves
        //           `listeners.size > 0` or increments `refreshes` after `stop()`.
        val listeners = CopyOnWriteArrayList<() -> Unit>()
        val refreshes = AtomicInteger(0)
        val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)
        try {
            val controller = ChildHomeRefreshController(
                addRulesChangedListener = { listeners.add(it) },
                removeRulesChangedListener = { listeners.remove(it) },
                onRefresh = { refreshes.incrementAndGet() },
                intervalMs = 30L,
            )

            controller.start(scope)
            assertTrue(controller.isRunning)
            assertEquals(1, listeners.size)

            // Rule change triggers immediate refresh.
            listeners.forEach { it() }
            assertEquals(1, refreshes.get())

            // Periodic foreground tick triggers additional refreshes while open (poll with 2 s deadline).
            val deadlineNs = System.nanoTime() + 2_000_000_000L
            while (refreshes.get() < 2 && System.nanoTime() < deadlineNs) {
                Thread.sleep(10L)
            }
            val beforeStop = refreshes.get()
            assertTrue("Expected periodic ticks to refresh while open (got $beforeStop)", beforeStop >= 2)

            // Stopping (called from PairingActivity.onPause) unregisters listener and halts ticks.
            controller.stop()
            assertFalse(controller.isRunning)
            assertEquals(0, listeners.size)

            val afterStop = refreshes.get()
            Thread.sleep(90L)
            assertEquals(
                "Expected zero refreshes after stop() / onPause()",
                afterStop,
                refreshes.get(),
            )
        } finally {
            scope.cancel()
        }
    }

    @Test
    fun `start while paused after suspended showStatus registers no listener and fires zero refreshes (#1283)`() {
        // Mutant: removing the `if (!isResumed()) return` guard in ChildHomeRefreshController.start()
        // registers a listener and starts the periodic ticker even though onPause() already ran.
        val listeners = CopyOnWriteArrayList<() -> Unit>()
        val refreshes = AtomicInteger(0)
        var resumed = false
        val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)
        try {
            val controller = ChildHomeRefreshController(
                addRulesChangedListener = { listeners.add(it) },
                removeRulesChangedListener = { listeners.remove(it) },
                onRefresh = { refreshes.incrementAndGet() },
                intervalMs = 30L,
                isResumed = { resumed },
            )

            // Simulates showStatus() resuming from a suspended report after onPause() already fired.
            controller.start(scope)
            assertFalse("Controller must not run when start() is called while paused", controller.isRunning)
            assertEquals("No rules listener may be registered while paused", 0, listeners.size)

            Thread.sleep(90L)
            assertEquals("Zero refreshes may fire while paused", 0, refreshes.get())

            // Returning to foreground (onResume) allows start() to activate cleanly, then pausing stops updates.
            resumed = true
            controller.start(scope)
            assertTrue(controller.isRunning)
            assertEquals(1, listeners.size)

            resumed = false
            listeners.forEach { it() }
            assertEquals("Paused listener callback must not refresh UI", 0, refreshes.get())
            controller.stop()
        } finally {
            scope.cancel()
        }
    }

    @Test
    fun `PairingActivity starts ChildHomeRefreshController on Child Home and stops it in onPause (#1283)`() {
        // Mutant: removing `activityResumed = false` / `stopChildHomeRefresh()` from `onPause()`,
        // `activityResumed = true` from `onResume()`, or `isChildHomeResumed()` guard fails these checks.
        assertEquals(60_000L, ChildHomeRefreshController.REFRESH_INTERVAL_MS)
        val activityFile = File(findAppSrcRoot(), "java/com/familyshield/agent/setup/PairingActivity.kt")
        val code = activityFile.readText()
        assertTrue(code.contains("override fun onPause() {\n        activityResumed = false\n        stopChildHomeRefresh()"))
        assertTrue(code.contains("override fun onResume() {\n        super.onResume()\n        activityResumed = true"))
        assertTrue(code.contains("lifecycle.currentState.isAtLeast(androidx.lifecycle.Lifecycle.State.RESUMED)"))
        assertTrue(code.contains("if (!isChildHomeResumed()) {"))
        assertTrue(code.contains("childHomeCopyState.value = initialCopy\n                startChildHomeRefresh()"))
        assertTrue(code.contains("addRulesChangedListener = { listener -> rules.addRulesChangedListener(listener) }"))
        assertTrue(code.contains("removeRulesChangedListener = { listener -> rules.removeRulesChangedListener(listener) }"))
    }

    private fun findAppSrcRoot(): File {
        var dir = File(System.getProperty("user.dir") ?: ".")
        repeat(5) {
            val candidate = File(dir, "src/main")
            if (candidate.isDirectory) return candidate
            val nested = File(dir, "app/src/main")
            if (nested.isDirectory) return nested
            dir = dir.parentFile ?: return candidate
        }
        return File("src/main")
    }
}
