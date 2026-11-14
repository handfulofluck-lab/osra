package com.familyshield.agent.receivers

import com.familyshield.agent.receivers.BroadcastGate.PackageFacts
import java.io.File
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * osra-security#8 F6: the exported receivers take only their own action, and the two that alert the parent
 * confirm the broadcast with PackageManager. Pure rows for the decision, then source rows that each receiver
 * asks it before doing anything (a JVM test cannot deliver a broadcast).
 */
class BroadcastGateTest {

    private val now = 1_800_000_000_000L

    @Test
    fun `each receiver takes only its own action`() {
        assertTrue(BroadcastGate.accepts("android.intent.action.BOOT_COMPLETED", "android.intent.action.BOOT_COMPLETED"))
        assertFalse(BroadcastGate.accepts("android.intent.action.BOOT_COMPLETED", "android.intent.action.PACKAGE_ADDED"))
        assertFalse(BroadcastGate.accepts("android.intent.action.PACKAGE_ADDED", null))
        assertFalse(BroadcastGate.accepts("android.intent.action.PACKAGE_ADDED", ""))
    }

    @Test
    fun `a spoofed PACKAGE_ADDED for a package that is not installed raises nothing`() {
        assertFalse(BroadcastGate.genuineInstall(null, now))
    }

    @Test
    fun `a PACKAGE_ADDED for an app installed long ago raises nothing`() {
        assertFalse(BroadcastGate.genuineInstall(PackageFacts(firstInstallMs = now - 3_600_000L, lastUpdateMs = now), now))
        assertFalse(BroadcastGate.genuineInstall(PackageFacts(firstInstallMs = 0L, lastUpdateMs = 0L), now))
    }

    @Test
    fun `a real install just now is reported`() {
        assertTrue(BroadcastGate.genuineInstall(PackageFacts(firstInstallMs = now - 2_000L, lastUpdateMs = now - 2_000L), now))
        assertTrue("clock slack", BroadcastGate.genuineInstall(PackageFacts(now + 30_000L, now + 30_000L), now))
        assertFalse("too far ahead", BroadcastGate.genuineInstall(PackageFacts(now + 120_000L, now + 120_000L), now))
        assertTrue("edge", BroadcastGate.genuineInstall(PackageFacts(now - BroadcastGate.FRESH_MS, 0L), now))
        assertFalse("past the edge", BroadcastGate.genuineInstall(PackageFacts(now - BroadcastGate.FRESH_MS - 1, 0L), now))
    }

    @Test
    fun `the agent-updated alert needs a real update of our own package just now`() {
        assertTrue(BroadcastGate.genuineSelfReplace(PackageFacts(firstInstallMs = now - 86_400_000L, lastUpdateMs = now - 5_000L), now))
        assertFalse(BroadcastGate.genuineSelfReplace(PackageFacts(firstInstallMs = now - 86_400_000L, lastUpdateMs = now - 86_400_000L), now))
        assertFalse(BroadcastGate.genuineSelfReplace(null, now))
    }

    // Source rows: each receiver asks the gate first, and the alerting ones before they post.

    @Test
    fun `every exported receiver checks its action with the gate first`() {
        for ((file, action) in listOf(
            "BootReceiver.kt" to "Intent.ACTION_BOOT_COMPLETED",
            "PackageAddedReceiver.kt" to "Intent.ACTION_PACKAGE_ADDED",
            "PackageReplacedReceiver.kt" to "Intent.ACTION_MY_PACKAGE_REPLACED",
        )) {
            val onReceive = receiver(file).substringAfter("override fun onReceive(", missingDelimiterValue = "")
            val firstStatement = onReceive.lines().drop(1).map { it.trim() }.first { it.isNotEmpty() && !it.startsWith("//") }
            assertTrue("$file: first statement is the gate", firstStatement == "if (!BroadcastGate.accepts($action, intent.action)) return")
        }
    }

    @Test
    fun `PackageAddedReceiver confirms the install before it posts`() {
        val src = receiver("PackageAddedReceiver.kt")
        val gate = src.indexOf("BroadcastGate.genuineInstall(packageFacts(context, packageId)")
        val post = src.indexOf("api.postInternalAlert(")
        assertTrue("asks the gate", gate >= 0)
        assertTrue("before posting", gate in 0 until post)
        assertTrue("from PackageManager", src.contains("context.packageManager.getPackageInfo(packageId, 0)"))
        assertTrue("with the first install time", src.contains("firstInstallMs = info.firstInstallTime"))
    }

    @Test
    fun `PackageReplacedReceiver confirms our own update before it posts`() {
        val src = receiver("PackageReplacedReceiver.kt")
        val gate = src.indexOf("BroadcastGate.genuineSelfReplace(ownFacts(context)")
        val post = src.indexOf("api.postInternalAlert(")
        assertTrue("asks the gate before posting", gate in 0 until post)
        assertTrue("our own package", src.contains("getPackageInfo(context.packageName, 0)"))
        assertTrue("its last update time", src.contains("lastUpdateMs = info.lastUpdateTime"))
    }

    private fun receiver(name: String) = sourceFile("app/src/main/java/com/familyshield/agent/receivers/$name")

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
