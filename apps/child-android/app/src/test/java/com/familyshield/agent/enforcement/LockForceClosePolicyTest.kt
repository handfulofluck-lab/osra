package com.familyshield.agent.enforcement

import com.familyshield.agent.commands.CommandOutcome
import com.familyshield.agent.commands.LockActivity
import java.io.File
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Issue #1183 after-test follow-up: verifies the default-off switch, Lock-only scope (never Pause
 * internet or Pause device), essential & always-allowed exemptions (with #1240 deny-set preserved),
 * honest Android ack detail (never claiming `force_stopped` or `signed_out` on consumer devices),
 * and Play vs Full manifest isolation.
 */
class LockForceClosePolicyTest {

    private val ownPkg = "com.osratech.child.full"

    private val testFacts = object : PackageFacts {
        override fun isSystemApp(pkg: String): Boolean =
            pkg in setOf("com.android.dialer", "com.android.phone", "com.android.systemui", "com.miui.home")
        override fun dialerRoleHolders(): Set<String> = setOf("com.android.dialer", "com.android.phone")
        override fun homePackages(): Set<String> = setOf("com.miui.home", "com.sec.android.app.launcher")
    }

    @Test
    fun `default-off switch starts false and produces no targets, no media pause, and no ack detail`() {
        assertFalse("default-off switch must start false for Saturday", LockForceCloseFlags.enabled)

        val plan = LockForceClosePolicy.plan(
            enabled = false,
            mode = LockActivity.MODE_LOCKED,
            installedPackages = listOf("com.youtube.android", "com.spotify.music"),
            ownPackage = ownPkg,
            alwaysAllowedPackages = emptySet(),
            facts = testFacts,
        )
        assertFalse(plan.shouldExecute)
        assertTrue(plan.targetPackages.isEmpty())

        assertFalse(
            LockForceClosePolicy.shouldPauseMediaUnderLock(
                enabled = false,
                mode = LockActivity.MODE_LOCKED,
                pkg = "com.youtube.android",
                ownPackage = ownPkg,
                alwaysAllowedPackages = emptySet(),
                facts = testFacts,
            ),
        )
        assertTrue(
            LockForceClosePolicy.ackDetailAdditions(
                enabled = false,
                mode = LockActivity.MODE_LOCKED,
                hasKillPermission = true,
                killedCount = 3,
            ).isEmpty(),
        )
    }

    @Test
    fun `strictly Lock-only — Pause internet, Pause device, and Unlock never close apps or pause media`() {
        for (mode in listOf(LockActivity.MODE_PAUSED_INTERNET, LockActivity.MODE_PAUSED, LockActivity.MODE_UNLOCK, null)) {
            val plan = LockForceClosePolicy.plan(
                enabled = true,
                mode = mode,
                installedPackages = listOf("com.youtube.android"),
                ownPackage = ownPkg,
                alwaysAllowedPackages = emptySet(),
                facts = testFacts,
            )
            assertFalse("mode=$mode must never run lock app close", plan.shouldExecute)
            assertTrue("mode=$mode must have empty targetPackages", plan.targetPackages.isEmpty())
            assertFalse(
                "mode=$mode must never pause media under lock",
                LockForceClosePolicy.shouldPauseMediaUnderLock(true, mode, "com.youtube.android", ownPkg, emptySet(), testFacts),
            )
            assertTrue(
                "mode=$mode must not add lock close ack details",
                LockForceClosePolicy.ackDetailAdditions(true, mode, hasKillPermission = true, killedCount = 2).isEmpty(),
            )
        }
    }

    @Test
    fun `under Lock, exempts own package, essential packages, and legitimate always-allowed apps while keeping #1240 deny-set`() {
        val installed = listOf(
            ownPkg,
            "com.android.dialer",
            "com.android.phone",
            "com.android.systemui",
            "com.miui.home",
            "org.khanacademy.android",
            "com.whatsapp",
            "com.android.vending", // Play Store: in LockEnforcementPolicy deny-set, not essential
            "com.youtube.android",
            "com.roblox.client",
            "com.roblox.client", // duplicate must dedupe
            "  ",
        )
        val alwaysAllowed = setOf(
            "org.khanacademy.android",
            "com.android.vending", // denied from always-allowed under Lock (#1240)
            "com.miui.home", // essential launcher stays protected by EssentialPackages
        )
        val plan = LockForceClosePolicy.plan(
            enabled = true,
            mode = LockActivity.MODE_LOCKED,
            installedPackages = installed,
            ownPackage = ownPkg,
            alwaysAllowedPackages = alwaysAllowed,
            facts = testFacts,
        )
        assertTrue(plan.shouldExecute)
        assertEquals(
            listOf("com.android.vending", "com.roblox.client", "com.whatsapp", "com.youtube.android"),
            plan.targetPackages,
        )

        // Media pause honors the exact same exemption boundary
        assertFalse(LockForceClosePolicy.shouldPauseMediaUnderLock(true, LockActivity.MODE_LOCKED, ownPkg, ownPkg, alwaysAllowed, testFacts))
        assertFalse(LockForceClosePolicy.shouldPauseMediaUnderLock(true, LockActivity.MODE_LOCKED, "com.android.dialer", ownPkg, alwaysAllowed, testFacts))
        assertFalse(LockForceClosePolicy.shouldPauseMediaUnderLock(true, LockActivity.MODE_LOCKED, "org.khanacademy.android", ownPkg, alwaysAllowed, testFacts))
        assertTrue(LockForceClosePolicy.shouldPauseMediaUnderLock(true, LockActivity.MODE_LOCKED, "com.youtube.android", ownPkg, alwaysAllowed, testFacts))
        assertTrue(LockForceClosePolicy.shouldPauseMediaUnderLock(true, LockActivity.MODE_LOCKED, "com.android.vending", ownPkg, alwaysAllowed, testFacts))
    }

    @Test
    fun `ack detail is honest on Full vs Play builds and never claims force_stopped or signed_out on consumer Android`() {
        val fullKilled = LockForceClosePolicy.ackDetailAdditions(
            enabled = true,
            mode = LockActivity.MODE_LOCKED,
            hasKillPermission = true,
            killedCount = 4,
            isDeviceOwner = false,
            deviceOwnerSignedOut = false,
        )
        assertEquals("background_killed", fullKilled["apps_closed"])
        assertEquals("4", fullKilled["apps_closed_count"])
        assertEquals("unsupported_android", fullKilled["session_ended"])

        val playCoveredOnly = LockForceClosePolicy.ackDetailAdditions(
            enabled = true,
            mode = LockActivity.MODE_LOCKED,
            hasKillPermission = false,
            killedCount = 4, // ignored when permission not held
            isDeviceOwner = false,
        )
        assertEquals("covered_only", playCoveredOnly["apps_closed"])
        assertEquals("0", playCoveredOnly["apps_closed_count"])
        assertEquals("unsupported_android", playCoveredOnly["session_ended"])

        val fullZeroTargets = LockForceClosePolicy.ackDetailAdditions(
            enabled = true,
            mode = LockActivity.MODE_LOCKED,
            hasKillPermission = true,
            killedCount = 0,
        )
        assertEquals("covered_only", fullZeroTargets["apps_closed"])
        assertEquals("0", fullZeroTargets["apps_closed_count"])
        assertEquals("unsupported_android", fullZeroTargets["session_ended"])
    }

    @Test
    fun `mergeAckDetail preserves existing Applied fields and never flips Refused into Applied`() {
        val additions = mapOf("apps_closed" to "background_killed", "session_ended" to "unsupported_android")
        val applied = CommandOutcome.Applied(mapOf("via" to "overlay"))
        val merged = LockForceClosePolicy.mergeAckDetail(applied, additions) as CommandOutcome.Applied
        assertEquals("overlay", merged.detail["via"])
        assertEquals("background_killed", merged.detail["apps_closed"])
        assertEquals("unsupported_android", merged.detail["session_ended"])

        val refused = CommandOutcome.Refused("lock_screen_unavailable")
        assertEquals(refused, LockForceClosePolicy.mergeAckDetail(refused, additions))
        assertEquals(applied, LockForceClosePolicy.mergeAckDetail(applied, emptyMap()))
    }

    @Test
    fun `wiring pins Lock-only execution and Play vs Full manifest split`() {
        val appDir = locateAppDir()
        val dispatcher = File(appDir, "src/main/java/com/familyshield/agent/commands/CommandDispatcher.kt").readText()
        val mainManifest = File(appDir, "src/main/AndroidManifest.xml").readText()
        val fullManifest = File(appDir, "src/full/AndroidManifest.xml").readText()

        assertTrue(dispatcher.contains("LockAppCloser.closeForLock"))
        assertTrue(dispatcher.contains("LockForceClosePolicy.mergeAckDetail"))

        // Verify pause() and pauseInternet() never invoke LockAppCloser
        val pauseFn = dispatcher.substringAfter("private fun pause()").substringBefore("private fun unlock()")
        val pauseInternetFn = dispatcher.substringAfter("private fun pauseInternet()").substringBefore("private fun resumeInternet()")
        assertFalse("pause() must never invoke LockAppCloser", pauseFn.contains("LockAppCloser"))
        assertFalse("pauseInternet() must never invoke LockAppCloser", pauseInternetFn.contains("LockAppCloser"))

        // Play manifest must never add KILL_BACKGROUND_PROCESSES; Full declares it
        assertFalse(mainManifest.contains("KILL_BACKGROUND_PROCESSES"))
        assertTrue(fullManifest.contains("android.permission.KILL_BACKGROUND_PROCESSES"))
    }

    private fun locateAppDir(): File {
        var dir: File? = File(System.getProperty("user.dir") ?: ".")
        repeat(6) {
            if (dir != null) {
                if (File(dir, "src/main/java/com/familyshield/agent").isDirectory) return dir!!
                val nested = File(dir, "app")
                if (File(nested, "src/main/java/com/familyshield/agent").isDirectory) return nested
                dir = dir!!.parentFile
            }
        }
        error("Could not locate apps/child-android/app from ${System.getProperty("user.dir")}")
    }
}
