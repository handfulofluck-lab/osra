package com.familyshield.agent.services

import java.io.File
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Issue #1054: wiring guards pinning that Android components (`CommandDispatcher`,
 * `LocationService`, `LocateWakeLock`, `LocationFixFetcher`, `FirebaseMessagingSvc`,
 * `CommandPoller`, `PairingActivity`, `FamilyShieldApp`) actually route through the pure policies
 * and seams tested in [LocateStrategyPolicyTest].
 */
class LocateLockedWiringTest {

    private val dispatcherSrc by lazy { source("app/src/main/java/com/familyshield/agent/commands/CommandDispatcher.kt") }
    private val locationServiceSrc by lazy { source("app/src/main/java/com/familyshield/agent/services/LocationService.kt") }
    private val wakeLockSrc by lazy { source("app/src/main/java/com/familyshield/agent/services/LocateWakeLock.kt") }
    private val fetcherSrc by lazy { source("app/src/main/java/com/familyshield/agent/services/LocationFixFetcher.kt") }
    private val fcmSrc by lazy { source("app/src/main/java/com/familyshield/agent/services/FirebaseMessagingSvc.kt") }
    private val pollerSrc by lazy { source("app/src/main/java/com/familyshield/agent/commands/CommandPoller.kt") }
    private val pairingSrc by lazy { source("app/src/main/java/com/familyshield/agent/setup/PairingActivity.kt") }
    private val appSrc by lazy { source("app/src/main/java/com/familyshield/agent/FamilyShieldApp.kt") }

    /**
     * Mutants killed:
     *  - dropping `LocateWakeLock.acquire(context)` or moving it after `startForegroundService`
     *    (CPU can sleep in Doze across the handoff);
     *  - removing `LocationFixFetcher.runDirectLocate` fallback on `startForegroundService` throw
     *    (API 31+ background FGS refusal dies immediately);
     *  - moving the fallback before `LocationStartPolicy` (bypassing permission checks);
     *  - omitting `LocateWakeLock.release()` in `finally` on the fallback path (leaking wake lock).
     */
    @Test
    fun `CommandDispatcher acquires PARTIAL_WAKE_LOCK before FGS start and falls back directly on FGS exception`() {
        val locateNow = dispatcherSrc
            .substringAfter("private fun locateNow(commandId: String?): CommandOutcome {")
            .substringBefore("private fun granted(")

        val policyIdx = locateNow.indexOf("LocationStartPolicy.Decision.START")
        val acquireIdx = locateNow.indexOf("LocateWakeLock.acquire(context)")
        val fgsIdx = locateNow.indexOf("ContextCompat.startForegroundService(")
        val catchIdx = locateNow.indexOf("catch (e: Exception)")
        val fallbackIdx = locateNow.indexOf("LocationFixFetcher.runDirectLocate(")
        val finallyIdx = locateNow.indexOf("finally")
        val releaseIdx = locateNow.indexOf("LocateWakeLock.release()", startIndex = finallyIdx.coerceAtLeast(0))

        assertTrue("locateNow must check LocationStartPolicy first", policyIdx >= 0)
        assertTrue("locateNow must acquire LocateWakeLock after policy check", acquireIdx > policyIdx)
        assertTrue("locateNow must acquire LocateWakeLock BEFORE startForegroundService", acquireIdx < fgsIdx)
        assertTrue("locateNow must hand wake-lock flag to LocationService", locateNow.contains("LocationService.EXTRA_HOLDS_WAKE_LOCK"))
        assertTrue("locateNow catch must fall back to LocationFixFetcher.runDirectLocate", fallbackIdx > catchIdx && catchIdx > fgsIdx)
        assertTrue("direct fallback must still ack via ackLocateNow", locateNow.contains("ackLocateNow(commandId, fix, uploaded)"))
        assertTrue("direct fallback must release LocateWakeLock in finally", finallyIdx > fallbackIdx && releaseIdx > finallyIdx)

        assertTrue("LocateWakeLock must use PowerManager.PARTIAL_WAKE_LOCK", wakeLockSrc.contains("PowerManager.PARTIAL_WAKE_LOCK"))
        assertTrue("LocateWakeLock must bound timeout with LocatePolicy.WAKE_LOCK_TIMEOUT_MS", wakeLockSrc.contains("LocatePolicy.WAKE_LOCK_TIMEOUT_MS"))
    }

    /**
     * Mutants killed:
     *  - calling `startUpdates(STATIONARY_INTERVAL_MS)` unconditionally in `onStartCommand`
     *    (tearing down active fused callbacks on every `ACTION_PING_NOW`);
     *  - failing to reset `updatesStarted = false` in `onDestroy`;
     *  - omitting `LocateWakeLock.release()` in `finally` inside `locateNowOnce` or on `!fgsStarted`.
     */
    @Test
    fun `LocationService guards startUpdates with updatesStarted and always releases LocateWakeLock`() {
        val onStart = locationServiceSrc
            .substringAfter("override fun onStartCommand(")
            .substringBefore("override fun onDestroy()")
        val onDestroy = locationServiceSrc
            .substringAfter("override fun onDestroy()")
            .substringBefore("override fun onBind(")
        val locateNowOnce = locationServiceSrc
            .substringAfter("private suspend fun locateNowOnce(")
            .substringBefore("private fun onLocation(")

        assertTrue("LocationService must declare updatesStarted", locationServiceSrc.contains("private var updatesStarted = false"))
        assertTrue("onStartCommand must guard startUpdates with if (!updatesStarted)", onStart.contains("if (!updatesStarted)"))
        assertTrue("onStartCommand must release LocateWakeLock if startForegroundCompat fails", onStart.contains("if (holdsWakeLock) LocateWakeLock.release()"))
        assertTrue("onDestroy must reset updatesStarted = false", onDestroy.contains("updatesStarted = false"))

        assertTrue("locateNowOnce must delegate to LocationFixFetcher.fetchLocation(fused)", locateNowOnce.contains("LocationFixFetcher.fetchLocation(fused)"))
        val finallyIdx = locateNowOnce.indexOf("finally")
        val releaseIdx = locateNowOnce.indexOf("LocateWakeLock.release()", startIndex = finallyIdx.coerceAtLeast(0))
        assertTrue("locateNowOnce must release LocateWakeLock in finally", finallyIdx >= 0 && releaseIdx > finallyIdx)
    }

    /**
     * Mutants killed:
     *  - dropping `PRIORITY_BALANCED_POWER_ACCURACY` from `LocationFixFetcher` (no Stage 2 fallback);
     *  - removing `consentState.isPaused()` guard in `runDirectLocate` (uploading during withdrawn consent).
     */
    @Test
    fun `LocationFixFetcher wires two-stage priorities and respects consent pause on direct fallback`() {
        assertTrue(fetcherSrc.contains("Priority.PRIORITY_HIGH_ACCURACY"))
        assertTrue(fetcherSrc.contains("Priority.PRIORITY_BALANCED_POWER_ACCURACY"))
        assertTrue(fetcherSrc.contains("fused.lastLocation"))
        assertTrue(fetcherSrc.contains("consentState.isPaused()"))
        assertTrue(fetcherSrc.contains("LocationService.FLUSH_MUTEX.withLock"))
    }

    /**
     * Mutant killed: leaving `settings.savePushToken(token)` only inside `scope.launch` in
     * `FirebaseMessagingSvc.onNewToken`, where FCM process freeze/kill can drop the token before
     * DataStore writes it to disk.
     */
    @Test
    fun `FirebaseMessagingSvc persists push token synchronously with runBlocking before async upload`() {
        val onNewToken = fcmSrc.substringAfter("override fun onNewToken(")
        val runBlockingIdx = onNewToken.indexOf("runBlocking")
        val saveIdx = onNewToken.indexOf("settings.savePushToken(token)")
        val launchIdx = onNewToken.indexOf("scope.launch")

        assertTrue("onNewToken must persist synchronously via runBlocking", runBlockingIdx >= 0)
        assertTrue("savePushToken must occur inside runBlocking before scope.launch", saveIdx > runBlockingIdx && saveIdx < launchIdx)
    }

    /**
     * Mutants killed:
     *  - dropping `runCatching` around `FirebaseMessaging.getInstance().token` (crashes FCM-free builds);
     *  - omitting proactive hydration from `CommandPoller.syncPushToken`, `PairingActivity.startAgent`,
     *    or `FamilyShieldApp.onCreate`.
     */
    @Test
    fun `proactive FCM token hydration is safely wrapped and wired at poll, pairing, and startup`() {
        val hydratorSrc = source("app/src/main/java/com/familyshield/agent/push/PushTokenHydrator.kt")
        assertTrue(
            "PushTokenHydrator must wrap FirebaseMessaging.getInstance().token in runCatching for FCM-free builds",
            hydratorSrc.contains("runCatching { FirebaseMessaging.getInstance().token }"),
        )
        assertTrue(
            "PushTokenHydrator must bound Firebase token wait with withTimeoutOrNull",
            hydratorSrc.contains("withTimeoutOrNull(FETCH_TIMEOUT_MS)"),
        )

        val syncPushToken = pollerSrc.substringAfter("suspend fun syncPushToken(")
        assertTrue("CommandPoller.syncPushToken must hydrate missing push token", syncPushToken.contains("PushTokenHydrator.hydrateIfMissing(settings)"))

        val startAgent = pairingSrc
            .substringAfter("private fun startAgent() {")
            .substringBefore("\n    }")
        assertTrue("PairingActivity.startAgent must hydrate missing push token", startAgent.contains("PushTokenHydrator.hydrateIfMissing(settings)"))

        val onCreate = appSrc.substringAfter("override fun onCreate()")
        assertTrue("FamilyShieldApp.onCreate must hydrate missing push token", onCreate.contains("PushTokenHydrator.hydrateIfMissing(entry.agentSettings())"))
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
