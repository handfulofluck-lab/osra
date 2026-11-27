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

            // Periodic foreground tick triggers additional refreshes while open.
            Thread.sleep(110L)
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
    fun `PairingActivity starts ChildHomeRefreshController on Child Home and stops it in onPause (#1283)`() {
        // Mutant: removing `stopChildHomeRefresh()` from `onPause()` or `startChildHomeRefresh()`
        // from `showStatus()` fails these wiring checks.
        assertEquals(60_000L, ChildHomeRefreshController.REFRESH_INTERVAL_MS)
        val activityFile = File(findAppSrcRoot(), "java/com/familyshield/agent/setup/PairingActivity.kt")
        val code = activityFile.readText()
        assertTrue(code.contains("override fun onPause() {\n        stopChildHomeRefresh()"))
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
