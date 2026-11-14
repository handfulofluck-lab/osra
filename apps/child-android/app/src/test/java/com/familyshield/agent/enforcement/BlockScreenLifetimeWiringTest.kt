package com.familyshield.agent.enforcement

import java.io.File
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Issue #671 (Flip4 scenario run 1, #665): a block screen the child left with Home is never finished, so
 * the next agent screen to close uncovers it — the ring at 19:10Z, or the keyguard's bouncer after an
 * unlock. The child read "This app is blocked by your parent · Calculator" with nothing blocked.
 *
 * [BlockRecheckPolicyTest] holds the decision table; this class holds the wiring that makes the screen
 * ask it. Source-text rows, the `UnlinkedOverlayWiringTest` shape: an activity a plain JVM test cannot
 * start, and the risk is that the policy is right and never called.
 *
 * Neither row proves that a real ring or a real unlock uncovers nothing. That is the phone row: SC-1.4
 * then SC-1.8 in one pairing, on the Flip4.
 *
 * Mutants: drop `closeIfNoLongerBlocked()` from `onResume` → [the block screen re-checks when it comes
 * back to the front]; drop it from `onStop` → [the block screen re-checks on the way out too]; read the
 * package from `intent` instead of `session.request` → [the re-check names the package on screen]; call
 * the policy and ignore its answer → [a FINISH answer takes the screen down].
 */
class BlockScreenLifetimeWiringTest {

    private val block = sourceFile("app/src/main/java/com/familyshield/agent/enforcement/BlockActivity.kt")

    private val onResume: String =
        block.substringAfter("override fun onResume()").substringBefore("/**")

    private val onStop: String =
        block.substringAfter("override fun onStop()").substringBefore("override fun onResume()")

    /** The private re-check both lifecycle callbacks share. */
    private val recheck: String =
        block.substringAfter("private fun closeIfNoLongerBlocked()").substringBefore("\n    }")

    @Test
    fun `the block screen re-checks when it comes back to the front`() {
        assertTrue(
            "a screen resumed after the ring or the keyguard must ask the rules again (#671)",
            onResume.contains("closeIfNoLongerBlocked()"),
        )
    }

    @Test
    fun `the block screen re-checks on the way out too`() {
        assertTrue(
            "a screen the child left with Home must not survive a block that has since been lifted (#671)",
            onStop.contains("closeIfNoLongerBlocked()"),
        )
    }

    @Test
    fun `the re-check names the package on screen`() {
        assertTrue(
            "the rules must be asked about the package the screen is showing (#217: singleTask reuses " +
                "the instance, so the intent is not the answer)",
            recheck.contains("session.request.packageId") && recheck.contains("rules.verdict(pkg)"),
        )
        assertTrue(
            "and the answer goes through the policy that holds the fail-closed rows",
            recheck.contains("BlockRecheckPolicy.decide(pkg,"),
        )
        assertTrue(
            "the rules are injected, not reached through the Application object",
            block.contains("@Inject lateinit var rules: RuleRepository"),
        )
    }

    @Test
    fun `a FINISH answer takes the screen down`() {
        assertTrue(
            "the policy's answer must reach finish(), or nothing is fixed",
            recheck.contains("BlockRecheckPolicy.Action.FINISH") && recheck.contains("finish()"),
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
