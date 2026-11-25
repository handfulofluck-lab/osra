package com.familyshield.agent.data

import java.io.File
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * #1130: a fresh or re-paired child must not wait for a parent save (or the six-hour tick) before it
 * has rules. WorkManager owns the retry/backoff; a paired empty cache is never a successful sync.
 *
 * Mutants: remove the startup `syncNow`, return success when refresh returns null, or restore the
 * second pairing-only request. Each leaves the corresponding row red while the old six-hour tests pass.
 */
class FreshInstallRulesWiringTest {

    private val scheduler = sourceFile("app/src/main/java/com/familyshield/agent/data/WorkScheduler.kt")
    private val worker = sourceFile("app/src/main/java/com/familyshield/agent/data/RulesSyncWorker.kt")
    private val pairing = sourceFile("app/src/main/java/com/familyshield/agent/setup/PairingActivity.kt")
    private val packageReplaced = sourceFile("app/src/main/java/com/familyshield/agent/receivers/PackageReplacedReceiver.kt")
    private val locationService = sourceFile("app/src/main/java/com/familyshield/agent/services/LocationService.kt")

    @Test
    fun `every scheduler start requests rules immediately instead of waiting for periodic work`() {
        val scheduleAll = scheduler.substringAfter("fun scheduleAll(").substringBefore("fun syncNow(")
        assertTrue(
            "scheduleAll must include the immediate one-time sync as well as the periodic worker",
            scheduleAll.contains("syncNow(context)"),
        )
    }

    @Test
    fun `a paired empty rules cache retries with WorkManager backoff`() {
        val doWork = worker.substringAfter("override suspend fun doWork(): Result").substringBefore("companion object")
        assertTrue("the refresh result must be inspected", doWork.contains("val rules = entryPoint.ruleRepository().refresh()"))
        assertTrue(
            "null rules on a paired device means retry, not a false success",
            doWork.contains("if (rules == null && entryPoint.agentSettings().isPaired())") &&
                doWork.contains("Result.retry()"),
        )
    }

    @Test
    fun `pairing does not enqueue a duplicate now that every start syncs`() {
        assertFalse(
            "scheduleAll owns the post-pairing immediate sync too; a second call doubles the fetch",
            pairing.contains("WorkScheduler.syncNow(this)"),
        )
    }

    @Test
    fun `package replacement enqueues the same durable rules refresh after the genuine-update gate`() {
        val gate = packageReplaced.indexOf("BroadcastGate.genuineSelfReplace(ownFacts(context)")
        val sync = packageReplaced.indexOf("WorkScheduler.syncNow(context)")
        val post = packageReplaced.indexOf("api.postInternalAlert(")
        assertTrue("a genuine replacement schedules rules before the best-effort alert", gate in 0 until sync && sync < post)
    }

    @Test
    fun `a foreground service restart requests the same immediate rules refresh`() {
        val onStart = locationService.substringAfter("override fun onStartCommand(").substringBefore("override fun onDestroy(")
        assertTrue(
            "service restart must not wait for boot, pairing, a push, or the six-hour tick",
            onStart.contains("WorkScheduler.syncNow(this)"),
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
