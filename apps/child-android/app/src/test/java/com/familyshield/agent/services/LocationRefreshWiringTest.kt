package com.familyshield.agent.services

import java.io.File
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Issue #1053: source-wiring guards pinning that `WorkScheduler`, `LocationRefreshWorker`,
 * `LocationService`, `LocationFixFetcher`, `PendingPingWorker`, `CommandDispatcher`, and
 * `AgentSettings` actually wire the pure rules tested in [LocationRefreshPolicyTest].
 */
class LocationRefreshWiringTest {

    private val schedulerSrc by lazy { source("app/src/main/java/com/familyshield/agent/data/WorkScheduler.kt") }
    private val workerSrc by lazy { source("app/src/main/java/com/familyshield/agent/services/LocationRefreshWorker.kt") }
    private val locationServiceSrc by lazy { source("app/src/main/java/com/familyshield/agent/services/LocationService.kt") }
    private val fetcherSrc by lazy { source("app/src/main/java/com/familyshield/agent/services/LocationFixFetcher.kt") }
    private val pendingWorkerSrc by lazy { source("app/src/main/java/com/familyshield/agent/services/PendingPingWorker.kt") }
    private val dispatcherSrc by lazy { source("app/src/main/java/com/familyshield/agent/commands/CommandDispatcher.kt") }
    private val settingsSrc by lazy { source("app/src/main/java/com/familyshield/agent/data/AgentSettings.kt") }

    /**
     * Mutants killed:
     *  - omitting `LocationRefreshWorker` from `WorkScheduler.scheduleAll` (periodic refresh never runs);
     *  - dropping `NetworkType.CONNECTED` constraint or switching `ExistingPeriodicWorkPolicy.KEEP` to
     *    `REPLACE`/`UPDATE` (resetting the 2h timer on every startup);
     *  - omitting `PendingPingWorker.schedule(context)` in `WorkScheduler.scheduleAll` (freshly paired
     *    phones lack Room ping-flush retry until their first reboot).
     */
    @Test
    fun `WorkScheduler scheduleAll enqueues LocationRefreshWorker with network KEEP policy and PendingPingWorker`() {
        val scheduleAll = schedulerSrc
            .substringAfter("fun scheduleAll(context: Context) {")
            .substringBefore("fun syncNow(")

        assertTrue(
            "WorkScheduler must build a NetworkType.CONNECTED constraint",
            scheduleAll.contains("NetworkType.CONNECTED"),
        )
        val enqueueBlock = scheduleAll
            .substringAfter("LocationRefreshWorker.WORK_NAME,", missingDelimiterValue = "")
            .substringBefore("PendingPingWorker.schedule(context)", missingDelimiterValue = "")
        assertTrue(
            "WorkScheduler.scheduleAll must enqueue LocationRefreshWorker before or alongside PendingPingWorker",
            enqueueBlock.isNotEmpty(),
        )
        assertTrue(
            "LocationRefreshWorker must use ExistingPeriodicWorkPolicy.KEEP",
            enqueueBlock.contains("ExistingPeriodicWorkPolicy.KEEP"),
        )
        assertTrue(
            "LocationRefreshWorker must use PeriodicWorkRequestBuilder<LocationRefreshWorker> with REFRESH_INTERVAL_HOURS and FLEX_INTERVAL_MINUTES",
            enqueueBlock.contains("PeriodicWorkRequestBuilder<LocationRefreshWorker>(") &&
                enqueueBlock.contains("LocationRefreshPolicy.REFRESH_INTERVAL_HOURS") &&
                enqueueBlock.contains("TimeUnit.HOURS") &&
                enqueueBlock.contains("LocationRefreshPolicy.FLEX_INTERVAL_MINUTES") &&
                enqueueBlock.contains("TimeUnit.MINUTES"),
        )
        assertTrue(
            "LocationRefreshWorker periodic request must require network connectivity",
            enqueueBlock.contains(".setConstraints(network)"),
        )
        assertTrue("REFRESH_INTERVAL_HOURS must stay <= 2L", LocationRefreshPolicy.REFRESH_INTERVAL_HOURS <= 2L)
        assertTrue(
            "WorkScheduler.scheduleAll must also call PendingPingWorker.schedule(context)",
            scheduleAll.contains("PendingPingWorker.schedule(context)"),
        )
    }

    /**
     * Mutants killed:
     *  - calling `startForegroundService` in `LocationRefreshWorker` (breaks Android 14+ background
     *    FGS restrictions and `LocationServiceStartSitesTest`);
     *  - using `PRIORITY_HIGH_ACCURACY` instead of `PRIORITY_BALANCED_POWER_ACCURACY` (draining battery
     *    with GNSS wakes every 2 hours);
     *  - bypassing `consentState.isPaused()`, `LocationRefreshPolicy.decide`,
     *    `LocationRefreshPolicy.choosePeriodicFix`, or `LocationService.FLUSH_MUTEX`;
     *  - dropping Room buffering (`dao.insertAll`) on network failure or `saveLastLocationUploadedAtMs`
     *    on 2xx upload.
     */
    @Test
    fun `LocationRefreshWorker runs balanced Doze-safe refresh under FLUSH_MUTEX without starting FGS`() {
        assertFalse(
            "LocationRefreshWorker must NEVER start a foreground service",
            workerSrc.contains("startForegroundService") || workerSrc.contains("setForeground"),
        )
        assertFalse(
            "LocationRefreshWorker must NEVER request PRIORITY_HIGH_ACCURACY",
            workerSrc.contains("PRIORITY_HIGH_ACCURACY"),
        )

        val doWork = workerSrc
            .substringAfter("override suspend fun doWork(): Result {")
            .substringBefore("private fun granted(")

        val decideIdx = doWork.indexOf("LocationRefreshPolicy.decide(")
        val balancedIdx = doWork.indexOf("Priority.PRIORITY_BALANCED_POWER_ACCURACY")
        val mutexIdx = doWork.indexOf("LocationService.FLUSH_MUTEX.withLock")
        val postIdx = doWork.indexOf("api.postLocationPings(")
        val saveIdx = doWork.indexOf("settings.saveLastLocationUploadedAtMs(")
        val catchIdx = doWork.indexOf("catch (e: Exception)")
        val roomBufferIdx = doWork.indexOf("dao.insertAll(")

        assertTrue("doWork must check consentState.isPaused()", doWork.contains("consentState.isPaused()"))
        assertTrue("doWork must call LocationRefreshPolicy.decide before acquiring location", decideIdx >= 0 && balancedIdx > decideIdx)
        assertTrue("doWork must request Priority.PRIORITY_BALANCED_POWER_ACCURACY", balancedIdx >= 0)
        assertTrue("worker must bound fresh fix with LocationRefreshPolicy.PERIODIC_FIX_TIMEOUT_MS", workerSrc.contains("LocationRefreshPolicy.PERIODIC_FIX_TIMEOUT_MS"))
        assertTrue("worker must gate cached fallback with LocationRefreshPolicy.choosePeriodicFix", workerSrc.contains("LocationRefreshPolicy.choosePeriodicFix("))
        assertTrue("doWork must upload inside LocationService.FLUSH_MUTEX.withLock", mutexIdx > balancedIdx && postIdx > mutexIdx)
        assertTrue(
            "doWork must re-check consentState.isPaused() inside FLUSH_MUTEX before postLocationPings",
            doWork.indexOf("consentState.isPaused()", startIndex = mutexIdx) in mutexIdx until postIdx,
        )
        assertTrue(
            "doWork must record saveLastLocationUploadedAtMs after postLocationPings on 2xx success (before catch)",
            saveIdx in (postIdx + 1) until catchIdx,
        )
        assertTrue(
            "doWork must buffer PendingPingEntity in Room on upload failure",
            roomBufferIdx > catchIdx,
        )
    }

    /**
     * Mutants killed:
     *  - omitting `saveLastLocationUploadedAtMs` in `LocationService.flushPings()` (active moving phones
     *    would still run `LocationRefreshWorker` location requests every 2 hours);
     *  - recording `saveLastLocationUploadedAtMs` on failed POSTs (hiding upload failures);
     *  - forgetting to clear `KEY_LAST_LOCATION_UPLOADED_AT_MS` in `AgentSettings.clearPairing()`
     *    (re-paired child inherits previous child's upload timestamp).
     */
    @Test
    fun `LocationService, LocationFixFetcher, PendingPingWorker, and AgentSettings maintain lastLocationUploadedAtMs`() {
        val flushPings = locationServiceSrc
            .substringAfter("suspend fun flushPings(): Boolean = FLUSH_MUTEX.withLock {")
            .substringBefore("private fun dropBuffered(")
        val postIdx = flushPings.indexOf("api.postLocationPings(")
        val saveIdx = flushPings.indexOf("settings.saveLastLocationUploadedAtMs(")
        val catchIdx = flushPings.indexOf("catch (e: Exception)")

        assertTrue(
            "LocationService.flushPings must record saveLastLocationUploadedAtMs after 2xx postLocationPings and before catch",
            postIdx >= 0 && saveIdx > postIdx && catchIdx > saveIdx,
        )

        val uploadSingle = fetcherSrc.substringAfter("private suspend fun uploadSingleLocation(")
        assertTrue(
            "LocationFixFetcher.uploadSingleLocation must record saveLastLocationUploadedAtMs on 2xx success",
            uploadSingle.indexOf("settings.saveLastLocationUploadedAtMs(") > uploadSingle.indexOf("api.postLocationPings("),
        )
        assertTrue(
            "CommandDispatcher must pass settings to LocationFixFetcher.runDirectLocate",
            dispatcherSrc.substringAfter("LocationFixFetcher.runDirectLocate(").substringBefore(")").contains("settings = settings"),
        )

        val pendingDoWork = pendingWorkerSrc
            .substringAfter("override suspend fun doWork(): Result {")
            .substringBefore("companion object")
        assertTrue(
            "PendingPingWorker.doWork must record saveLastLocationUploadedAtMs on 2xx upload",
            pendingDoWork.indexOf("settings.saveLastLocationUploadedAtMs(") > pendingDoWork.indexOf("postLocationPings("),
        )

        assertTrue("AgentSettings must expose suspend fun lastLocationUploadedAtMs()", settingsSrc.contains("suspend fun lastLocationUploadedAtMs(): Long?"))
        assertTrue("AgentSettings must expose suspend fun saveLastLocationUploadedAtMs(epochMs: Long)", settingsSrc.contains("suspend fun saveLastLocationUploadedAtMs(epochMs: Long)"))
        val clearPairing = settingsSrc
            .substringAfter("suspend fun clearPairing() {")
            .substringBefore("fun baseUrlSync()")
        assertTrue(
            "AgentSettings.clearPairing must clear KEY_LAST_LOCATION_UPLOADED_AT_MS on re-pair",
            clearPairing.contains("it.remove(KEY_LAST_LOCATION_UPLOADED_AT_MS)"),
        )
    }

    private fun source(relative: String): String {
        var dir: File? = File(System.getProperty("user.dir") ?: ".").absoluteFile
        while (dir != null) {
            val candidate = File(dir, relative)
            if (candidate.isFile) return candidate.readText()
            dir = dir.parentFile
        }
        throw AssertionError("could not find $relative from ${System.getProperty("user.dir")}")
    }
}
