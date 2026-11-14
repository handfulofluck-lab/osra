package com.familyshield.agent.manifest

import java.io.File
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Before
import org.junit.Test

/**
 * Issue #671 (Flip4 scenario run 1, #665): `BlockActivity`, `LockActivity`, `RingActivity` and
 * `SosActivity` shared the application's task affinity, so every one of them landed in the **one** task
 * the app already had. A block screen the child left with Home was therefore still underneath: the ring
 * screen went into the same task on top of it, and when the ring stopped the block screen the parent had
 * lifted seven minutes earlier was uncovered.
 *
 * Each overlay is now the root of a task of its own and declares `excludeFromRecents`, so closing one
 * returns to whatever was really underneath it — the home screen, or the app the child was in — and the
 * overlay never appears as a task card either.
 *
 * Asserted on the **merged** Play manifest, the artefact the phone installs (finding F2, #101 review),
 * the same way `PlayMergedManifestTest` reads its permissions. The attributes come from `src/main`, so
 * both flavours carry them.
 *
 * [the pairing screen keeps the app's own affinity] is the control, not decoration: `null` (absent) and
 * `""` (declared empty) are the two answers this gate must never confuse. If the reader ever collapsed
 * them, that row fails while the four overlay rows above stay green.
 *
 * Mutants, one per row: delete `android:taskAffinity=""` from one of the four activities → that
 * activity's row goes red (the other three stay green); delete `android:excludeFromRecents="true"` from
 * one → that row goes red.
 */
class TransientScreenTaskTest {

    private val artifact: File? by lazy { MergedManifestLocator.locate("play") }
    private val merged: MergedManifest by lazy { MergedManifest.read(artifact!!) }

    @Before
    fun theMergedManifestMustExist() {
        MergedManifestLocator.require(artifact, "play")
        println("transient-screen task gate (play debug): ${artifact!!.absolutePath}")
    }

    /** The four screens a parent or the child puts up and that must never stack on each other. */
    private fun overlay(name: String): MergedManifest.Component =
        merged.components.firstOrNull { it.tag == "activity" && it.name == name }
            ?: throw AssertionError("no <activity android:name=\"$name\"> in the merged Play manifest")

    private fun assertOwnTaskAndUnlisted(name: String) {
        val screen = overlay(name)
        assertEquals(
            "$name must keep reusing its instance (#217: a second block re-delivers through onNewIntent)",
            "singleTask",
            screen.launchMode,
        )
        assertEquals(
            "$name must declare android:taskAffinity=\"\" so it is the root of its own task. Absent, it " +
                "joins the application's task and an earlier overlay is uncovered when this one closes (#671).",
            "",
            screen.taskAffinity,
        )
        assertEquals(
            "$name must declare android:excludeFromRecents=\"true\": an overlay is not a task the child " +
                "should find in Recents (#671).",
            "true",
            screen.excludeFromRecents,
        )
    }

    @Test
    fun `the block screen is the root of its own task and stays out of recents`() {
        assertOwnTaskAndUnlisted("com.familyshield.agent.enforcement.BlockActivity")
    }

    @Test
    fun `the lock screen is the root of its own task and stays out of recents`() {
        assertOwnTaskAndUnlisted("com.familyshield.agent.commands.LockActivity")
    }

    @Test
    fun `the ring screen keeps the app's own task, so the alarm can be stopped from the handset`() {
        // Issue #734, found by Karim on the Flip4 during this PR's device row. Handing the ring screen an
        // affinity of its own made it outlive Home in a hidden task: the phone kept ringing and the only
        // way to stop it - the parent PIN on that screen - could not be reached. It is the one overlay that
        // stays in the application's task; the block, lock and SOS screens are the ones that must not stack.
        val ring = overlay("com.familyshield.agent.commands.RingActivity")
        assertEquals(
            "RingActivity must keep reusing its instance",
            "singleTask",
            ring.launchMode,
        )
        assertNull(
            "RingActivity must NOT declare a task affinity: alone in its own task it cannot be reached " +
                "once the child presses Home, and a ringing phone that the handset cannot silence is " +
                "worse than the stacking bug this PR fixes (#734).",
            ring.taskAffinity,
        )
        assertEquals(
            "RingActivity stays out of Recents: it is still not a task the child should find there.",
            "true",
            ring.excludeFromRecents,
        )
    }

    @Test
    fun `the SOS screen is the root of its own task and stays out of recents`() {
        assertOwnTaskAndUnlisted("com.familyshield.agent.sos.SosActivity")
    }

    /**
     * Fable's g10 (#731 review): none of the four overlays may be started by another app. An exported
     * block or lock screen is something any installed app could raise at the child.
     */
    @Test
    fun `no overlay screen can be started by another app`() {
        for (name in listOf(
            "com.familyshield.agent.enforcement.BlockActivity",
            "com.familyshield.agent.commands.LockActivity",
            "com.familyshield.agent.commands.RingActivity",
            "com.familyshield.agent.sos.SosActivity",
        )) {
            assertEquals("$name must not be exported", "false", overlay(name).exported)
        }
    }

    /**
     * The control. `PairingActivity` is the launcher entry and must keep the application's affinity: it
     * is the app's task. Both attributes are absent today, so this row also proves the gate reads
     * absence as `null` rather than as the empty string.
     */
    @Test
    fun `the pairing screen keeps the app's own affinity`() {
        val pairing = overlay("com.familyshield.agent.setup.PairingActivity")
        assertNull(
            "PairingActivity must not declare a task affinity: it is the application's own task, and " +
                "this row is what makes the four empty-affinity rows above mean something.",
            pairing.taskAffinity,
        )
        assertNull("the launcher screen is a task the child may find in Recents", pairing.excludeFromRecents)
    }
}
