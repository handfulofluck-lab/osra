package com.familyshield.agent

import java.io.File
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Issue #473: the wiring that carries a [com.familyshield.agent.data.WindowReason] from the engine to the
 * block screen, across three files the JVM cannot start: the service that decides, `AppBlocker` that
 * launches, and the Compose screen that renders.
 *
 * Each half is a separate failure: a window computed but not passed is dead code; extras written but not
 * read is a silent no-op; and both are invisible to the copy rows, which only see the sentence.
 *
 * Mutants: drop the `window` parameter from `showBlockScreen`, drop the `putExtra` block, or drop
 * `windowFrom(intent)` from `applyIntent` — each turns the assertion that names it red.
 */
class BlockWindowWiringTest {

    private val blocker = sourceFile("app/src/main/java/com/familyshield/agent/enforcement/AppBlocker.kt")
    private val activity = sourceFile("app/src/main/java/com/familyshield/agent/enforcement/BlockActivity.kt")
    private val session = sourceFile("app/src/main/java/com/familyshield/agent/enforcement/BlockSession.kt")
    private val service = sourceFile("app/src/main/java/com/familyshield/agent/services/AccessibilityMonitorService.kt")

    @Test
    fun `the decision passes the window it computed`() {
        assertTrue(
            "the service must ask the repository which window fired",
            service.contains("blocker.showBlockScreen(pkg, rules.windowFor(pkg))"),
        )
        assertTrue(
            "and only for a block — a time limit has no window",
            service.contains("else blocker.showTimeLimitScreen(pkg)"),
        )
    }

    @Test
    fun `the launcher writes the extras only when a window is present`() {
        assertTrue(blocker.contains("fun showBlockScreen(pkg: String, window: WindowReason? = null)"))
        assertTrue(
            "an absent window must add nothing, so the screen keeps today's copy",
            blocker.contains("if (window != null) {") &&
                blocker.contains("putExtra(BlockActivity.EXTRA_WINDOW_KIND, window.kind.name)") &&
                blocker.contains("putExtra(BlockActivity.EXTRA_WINDOW_ENDS, window.endsAt)"),
        )
    }

    @Test
    fun `the screen reads the extras into the request, not into local state`() {
        assertTrue(
            "singleTask reuses the instance, so the window belongs to the request, not to local state",
            session.contains("val window: WindowReason? = null") && session.contains("BlockRequest(packageId.orEmpty(), reason ?: BlockActivity.REASON_BLOCKED, window)"),
        )
        assertTrue(activity.contains("windowFrom(intent)"))
        assertTrue(
            "an unknown kind or a missing end reads as no window rather than half a sentence",
            activity.contains("WindowKind.valueOf(kind) }.getOrNull() ?: return null") &&
                activity.contains("EXTRA_WINDOW_ENDS) ?: return null"),
        )
        assertTrue(
            "the line is rendered from the request",
            activity.contains("BlockWindowCopy.line(window)") && activity.contains("window = request.window"),
        )
    }

    private fun sourceFile(relative: String): String {
        var dir: File? = File(System.getProperty("user.dir")).absoluteFile
        while (dir != null) {
            val candidate = File(dir, relative)
            if (candidate.isFile) return candidate.readText()
            dir = dir.parentFile
        }
        throw AssertionError("could not find $relative from ${System.getProperty("user.dir")}")
    }
}
