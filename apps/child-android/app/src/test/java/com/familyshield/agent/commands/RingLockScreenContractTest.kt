package com.familyshield.agent.commands

import java.io.File
import javax.xml.parsers.DocumentBuilderFactory
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import org.w3c.dom.Element

/**
 * Issue #866: on a locked Flip4 the ring was loud and immediate, but the "enter parent PIN to stop" screen sat
 * **behind** Samsung's keyguard — there was nothing to type into, and the ring only stopped when the parent sent
 * `stop_ring` from the app.
 *
 * The behaviour was fixed at `616b56d9`: an activity that does not ask to be shown over the lock screen gets the
 * keyguard instead, and that is a one-line property of each activity. This test pins the property on both screens a
 * parent-in-a-hurry needs — the ring itself and the PIN gate it opens — so a refactor that rewrites either
 * `onCreate` cannot silently put the keyguard back in front of them.
 *
 * **What this is not:** it is a source/manifest contract test, not an instrumentation or Robolectric test. It proves
 * the requests are still present in the code and the manifest; only a device run proves Android honours them over a
 * real keyguard (the row is in #866's "fix wanted" item 3 and needs a lease).
 *
 * **Running a mutant:** Gradle does not treat `AndroidManifest.xml` as an input of the unit-test task, so an
 * XML-only mutant is reported as UP-TO-DATE and the previous (green) result is printed. Use `--rerun`; without it
 * the manifest mutant below "passes" while the attribute is gone, which is exactly the false green this comment
 * exists to prevent.
 *
 * Mutants, each of which must red this file:
 *  - remove `setShowWhenLocked(true)` from `RingActivity` → the ring row fails;
 *  - remove it from `TamperGuardActivity` → the gate row fails;
 *  - drop `android:showWhenLocked="true"` from the manifest entry → the manifest row fails.
 */
class RingLockScreenContractTest {

    private val ringActivity by lazy { source("app/src/main/java/com/familyshield/agent/commands/RingActivity.kt").readText() }
    private val gateActivity by lazy { source("app/src/main/java/com/familyshield/agent/security/TamperGuardActivity.kt").readText() }
    private val manifest by lazy { parse(source("app/src/main/AndroidManifest.xml")) }

    @Test
    fun `the ring screen asks to be shown over the lock screen and to turn it on`() {
        assertTrue(
            "RingActivity must call setShowWhenLocked(true) — without it the keyguard covers the ring (#866)",
            ringActivity.contains("setShowWhenLocked(true)"),
        )
        assertTrue(
            "RingActivity must call setTurnScreenOn(true) — a locked, dark phone must light up for a ring (#866)",
            ringActivity.contains("setTurnScreenOn(true)"),
        )
    }

    @Test
    fun `the PIN gate asks to be shown over the lock screen too`() {
        // The gate is what the parent taps from the ring screen; if it loses the flag, the ring can be heard but
        // never stopped on a locked phone, which is the field report this issue came from.
        assertTrue(
            "TamperGuardActivity must call setShowWhenLocked(true) — otherwise the keyguard comes up instead of the gate (#866)",
            gateActivity.contains("setShowWhenLocked(true)"),
        )
        assertTrue(
            "TamperGuardActivity must call setTurnScreenOn(true) — the gate must be reachable while the screen is off (#866)",
            gateActivity.contains("setTurnScreenOn(true)"),
        )
    }

    @Test
    fun `the ring activity's manifest entry keeps the lock-screen attributes`() {
        val entry = activity("commands.RingActivity")
        assertEquals("RingActivity must stay showWhenLocked in the manifest", "true", entry.getAttribute("android:showWhenLocked"))
        assertEquals("RingActivity must stay turnScreenOn in the manifest", "true", entry.getAttribute("android:turnScreenOn"))
        assertEquals("RingActivity must not be exported", "false", entry.getAttribute("android:exported"))
    }

    @Test
    fun `both screens keep the API-27 guard rather than calling the setters unconditionally`() {
        // minSdk is 26: setShowWhenLocked/setTurnScreenOn exist from O_MR1 (27). Calling them unguarded would
        // compile and then throw NoSuchMethodError on an API-26 handset — the oldest device we claim to support.
        assertTrue(
            "RingActivity must guard the lock-screen calls with an API-27 check",
            ringActivity.contains("VERSION_CODES.O_MR1"),
        )
        assertTrue(
            "TamperGuardActivity must guard the lock-screen calls with an API-27 check",
            gateActivity.contains("VERSION_CODES.O_MR1"),
        )
    }

    private fun activity(nameSuffix: String): Element {
        val activities = manifest.getElementsByTagName("activity")
        for (index in 0 until activities.length) {
            val element = activities.item(index) as Element
            if (element.getAttribute("android:name").endsWith(nameSuffix)) return element
        }
        throw AssertionError("AndroidManifest.xml declares no activity ending with $nameSuffix")
    }

    private fun source(relative: String): File {
        var dir: File? = File(System.getProperty("user.dir") ?: ".").absoluteFile
        while (dir != null) {
            val candidate = File(dir, relative)
            if (candidate.isFile) return candidate
            dir = dir.parentFile
        }
        throw AssertionError("could not find $relative from ${System.getProperty("user.dir")}")
    }

    private fun parse(file: File): Element {
        val factory = DocumentBuilderFactory.newInstance().apply { isNamespaceAware = false }
        return factory.newDocumentBuilder().parse(file).documentElement
    }
}
