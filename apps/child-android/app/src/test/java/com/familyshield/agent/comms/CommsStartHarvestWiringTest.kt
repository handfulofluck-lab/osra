package com.familyshield.agent.comms

import java.io.File
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Issue #520: after a force-stop, two texts already in the SMS table were still not on the server through two
 * 5-minute flushes, and landed only when another text arrived and the app was opened.
 *
 * The cause was ordering, not a missing path: `start()` registered the observers and then waited a full
 * period before its first harvest, so a flush could run against a table nobody had read. `harvestNow()` is
 * the suspendable body `onPermissionsChanged` used to launch, and `start()` now runs it **before** its first
 * flush.
 *
 * `CommsLogger` needs a ContentProvider and a database, so what is pinned here is the order of the statements
 * in the service's own start path — the part that was wrong.
 *
 * Mutants: delete the start-time `harvestNow()` and
 * [the service harvests once before its first flush] goes red; move it after the flush and
 * [the harvest precedes the flush, not the other way round] goes red.
 */
class CommsStartHarvestWiringTest {

    private val logger = sourceFile("app/src/full/java/com/familyshield/agent/comms/CommsLogger.kt")

    @Test
    fun `the service harvests once before its first flush`() {
        val start = startBody()
        // Before the loop, not merely somewhere in it: a harvest that only happens on the first 5-minute
        // tick is exactly the delay this issue measured.
        val beforeLoop = start.substringBefore("while (isActive)")
        assertTrue(
            "start() must harvest what is already in the table instead of waiting for the next text",
            beforeLoop.contains("harvestNow()"),
        )
        assertTrue(
            "and the loop must still harvest on every tick",
            snippet(start, "while (isActive)").contains("harvestNow()"),
        )
    }

    @Test
    fun `the harvest precedes the flush, not the other way round`() {
        // The measured failure: a flush of a table nobody had read, twice. Ordering is the whole fix.
        val start = startBody()
        val harvest = start.indexOf("harvestNow()")
        val flush = start.indexOf("flush()")
        assertTrue("both must be in the start path", harvest >= 0 && flush >= 0)
        assertTrue("the harvest runs first, the flush second", harvest < flush)
    }

    @Test
    fun `the retry entry point still harvests, because Android calls it synchronously`() {
        // #229 added onPermissionsChanged for the permission result, onResume and the loop. It launches the
        // same body rather than duplicating it, so the two cannot drift.
        val entry = snippet(logger, "override fun onPermissionsChanged()")
        assertTrue("it launches the shared body", entry.contains("harvestNow()"))
    }

    /** The body of `start()`, up to the closing brace that ends it. */
    private fun startBody(): String {
        val start = logger.indexOf("override fun start()")
        assertTrue("start() must exist", start > 0)
        val end = logger.indexOf("override fun onPermissionsChanged()", start)
        assertTrue("the next member marks the end", end > start)
        return logger.substring(start, end)
    }

    /** From [marker] to the next blank line — enough to see which calls a block makes. */
    private fun snippet(source: String, marker: String): String {
        val at = source.indexOf(marker)
        assertTrue("$marker must exist", at > 0)
        return source.substring(at).substringBefore("\n\n", missingDelimiterValue = source.substring(at))
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
