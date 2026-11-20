package com.familyshield.agent.content

import com.familyshield.agent.data.RuleRepository
import com.familyshield.agent.data.db.PendingScanDao
import com.familyshield.agent.data.db.PendingScanEntity
import com.familyshield.agent.network.ApiService
import com.familyshield.agent.network.dto.ActivityEventBatchDto
import com.familyshield.agent.network.dto.AlertDto
import com.familyshield.agent.network.dto.BlocklistPackDto
import com.familyshield.agent.network.dto.CommandAckDto
import com.familyshield.agent.network.dto.DeviceCommandDto
import com.familyshield.agent.network.dto.InstalledAppsDto
import com.familyshield.agent.network.dto.LocationPingBatchDto
import com.familyshield.agent.network.dto.PushTokenDto
import com.familyshield.agent.network.dto.RuleSetDto
import com.familyshield.agent.network.dto.SearchEventDto
import com.familyshield.agent.network.dto.SocialScanBatchDto
import com.familyshield.agent.network.dto.SocialScanBatchResultDto
import com.familyshield.agent.network.dto.SocialScanDto
import com.familyshield.agent.network.dto.SocialScanItemResultDto
import com.familyshield.agent.network.dto.TelemetryDto
import com.familyshield.agent.social.ScanQueuePolicy
import com.familyshield.agent.social.SocialScanQueue
import java.io.IOException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.delay
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import retrofit2.Response

/**
 * Contract tests for `osra-security#45`:
 * - default-off (`absent` / `null` / `false`) and revoked `searchMonitoring` opt-in
 * - minimal payload (`SearchEventDto` & `ParsedSearch` drop URL data)
 * - consent pause & approval-epoch enforcement during enqueue & upload
 * - full opt-out cleanup beyond `BATCH_SIZE` in a realistic mixed backlog + re-enable path
 * - delayed `flushJob` lifecycle without self-cancellation and process-restart recovery.
 */
class SearchDurableQueueTest {

    private class FakePendingScanDao : PendingScanDao {
        private var nextId = 1L
        var failDeleteBefore: Boolean = false
        val rows = mutableListOf<PendingScanEntity>()

        override suspend fun insert(scan: PendingScanEntity): Long {
            val id = nextId++
            rows.add(scan.copy(id = id))
            return id
        }

        override suspend fun oldest(limit: Int): List<PendingScanEntity> =
            rows.sortedBy { it.createdAt }.take(limit)

        override suspend fun delete(id: Long) {
            rows.removeAll { it.id == id }
        }

        override suspend fun bumpAttempts(id: Long) {
            val idx = rows.indexOfFirst { it.id == id }
            if (idx >= 0) rows[idx] = rows[idx].copy(attempts = rows[idx].attempts + 1)
        }

        override suspend fun count(): Int = rows.size

        override suspend fun purge(olderThanMs: Long, maxAttempts: Int): Int {
            val before = rows.size
            rows.removeAll { it.createdAt < olderThanMs || it.attempts >= maxAttempts }
            return before - rows.size
        }

        override suspend fun deleteBySource(source: String): Int {
            val before = rows.size
            rows.removeAll { it.source == source }
            return before - rows.size
        }

        override suspend fun deleteBefore(beforeMs: Long): Int {
            if (failDeleteBefore) throw IOException("cleanup failed")
            val before = rows.size
            rows.removeAll { it.createdAt < beforeMs }
            return before - rows.size
        }
    }

    private class FakeSearchApi : ApiService {
        var offline = false
        val postedSearches = mutableListOf<SearchEventDto>()
        val postedSocialBatches = mutableListOf<SocialScanBatchDto>()

        override suspend fun postSearchEvent(event: SearchEventDto) {
            if (offline) throw IOException("network unavailable")
            postedSearches.add(event)
        }

        override suspend fun postSocialScanBatch(batch: SocialScanBatchDto): SocialScanBatchResultDto {
            if (offline) throw IOException("network unavailable")
            postedSocialBatches.add(batch)
            return SocialScanBatchResultDto(batch.items.map { SocialScanItemResultDto(ok = true) })
        }

        override suspend fun postInternalAlert(alert: AlertDto) {}
        override suspend fun getRules(childId: String): RuleSetDto = throw UnsupportedOperationException()
        override suspend fun postLocationPings(batch: LocationPingBatchDto) = throw UnsupportedOperationException()
        override suspend fun postTelemetry(deviceId: String, telemetry: TelemetryDto) = throw UnsupportedOperationException()
        override suspend fun postInstalledApps(deviceId: String, body: InstalledAppsDto) = throw UnsupportedOperationException()
        override suspend fun postPushToken(deviceId: String, body: PushTokenDto) = throw UnsupportedOperationException()
        override suspend fun getCommands(deviceId: String, ackCapable: Int): List<DeviceCommandDto> = throw UnsupportedOperationException()
        override suspend fun getCommandsWithCadence(deviceId: String, ackCapable: Int): Response<List<DeviceCommandDto>> = throw UnsupportedOperationException()
        override suspend fun ackCommand(deviceId: String, commandId: String, body: CommandAckDto) = throw UnsupportedOperationException()
        override suspend fun getBlocklists(): BlocklistPackDto = throw UnsupportedOperationException()
        override suspend fun postSocialScan(scan: SocialScanDto) = throw UnsupportedOperationException()
        override suspend fun postActivityEvents(deviceId: String, batch: ActivityEventBatchDto) = throw UnsupportedOperationException()
    }

    @Test
    fun `search monitoring defaults to disabled for absent or false rules and allows explicit true`() {
        assertFalse(RuleRepository.isSearchMonitoringEnabled(null))
        assertFalse(RuleRepository.isSearchMonitoringEnabled(RuleSetDto(searchMonitoring = null)))
        assertFalse(RuleRepository.isSearchMonitoringEnabled(RuleSetDto(searchMonitoring = false)))
        assertTrue(RuleRepository.isSearchMonitoringEnabled(RuleSetDto(searchMonitoring = true)))
    }

    @Test
    fun `search payloads exclude url metadata completely`() {
        val dtoFields = SearchEventDto::class.java.declaredFields
            .filter { !it.isSynthetic && !java.lang.reflect.Modifier.isStatic(it.modifiers) }
            .map { it.name }
            .toSet()
        assertFalse("SearchEventDto must not carry url", dtoFields.contains("url"))
        assertEquals(setOf("childId", "deviceId", "engine", "query", "timestamp"), dtoFields)

        val parsedFields = ParsedSearch::class.java.declaredFields
            .filter { !it.isSynthetic && !java.lang.reflect.Modifier.isStatic(it.modifiers) }
            .map { it.name }
            .toSet()
        assertFalse("ParsedSearch must not carry url", parsedFields.contains("url"))
        assertEquals(setOf("engine", "query"), parsedFields)
    }

    @Test
    fun `durable queue honors consent epoch, purges all search rows beyond batch size on opt-out, and recovers across restart`() = runBlocking {
        val dao = FakePendingScanDao()
        val api = FakeSearchApi()
        var optIn = false
        var paused = false
        var epoch = 0L
        var resumedAtMs = 0L
        var storedEpoch: Long? = null
        var retryCount = 0

        fun newQueueInstance(): SocialScanQueue = SocialScanQueue(
            api = api,
            dao = dao,
            childIdProvider = { "child-1" },
            deviceIdProvider = { "dev-1" },
            allowlistProvider = { emptyList() },
            searchMonitoringEnabledProvider = { optIn },
            consentPausedProvider = { paused },
            consentEpochProvider = { epoch },
            consentResumedAtProvider = { resumedAtMs },
            getStoredConsentEpoch = { storedEpoch },
            setStoredConsentEpoch = { storedEpoch = it },
            retryScheduler = { retryCount++ },
        )

        // 1. Absent/disabled opt-in: enqueue refuses cleanly.
        val q1 = newQueueInstance()
        assertFalse(q1.enqueueForFlush(app = "google", contact = null, text = "science fair", nowMs = 1_000L, source = ScanQueuePolicy.SOURCE_SEARCH))
        assertEquals(0, dao.count())

        // 2. Opt-in enabled while offline: durable row persists, then delivers after restart when online.
        optIn = true
        api.offline = true
        val baseNow = System.currentTimeMillis()
        assertTrue(q1.enqueueForFlush(app = "google", contact = null, text = "science fair", nowMs = baseNow, source = ScanQueuePolicy.SOURCE_SEARCH))
        q1.flush()
        assertTrue(api.postedSearches.isEmpty())
        assertEquals(1, dao.rows.single().attempts)
        assertEquals(1, retryCount)

        api.offline = false
        val restartedQueue = newQueueInstance()
        restartedQueue.flush()
        assertEquals(0, dao.count())
        assertEquals(1, api.postedSearches.size)
        assertEquals("google", api.postedSearches.single().engine)
        assertEquals("science fair", api.postedSearches.single().query)

        // 3. Realistic mixed backlog > BATCH_SIZE (55 older social rows + 5 newer search rows):
        //    revoking search opt-out deletes ALL pending search rows (even past BATCH_SIZE=50),
        //    while social rows continue flushing; re-enabling opt-in captures again.
        for (i in 1..55) {
            dao.insert(PendingScanEntity(app = "whatsapp", contact = "Alex", text = "msg $i", source = ScanQueuePolicy.SOURCE_SCREEN, createdAt = baseNow + i))
        }
        for (j in 1..5) {
            dao.insert(PendingScanEntity(app = "youtube", contact = null, text = "query $j", source = ScanQueuePolicy.SOURCE_SEARCH, createdAt = baseNow + 100 + j))
        }
        assertEquals(60, dao.count())
        optIn = false
        restartedQueue.flush()
        assertTrue("all search rows past BATCH_SIZE must be purged on opt-out", dao.rows.none { it.source == ScanQueuePolicy.SOURCE_SEARCH })
        assertEquals(5, dao.count()) // 5 remaining social rows after BATCH_SIZE=50 flushed
        assertTrue(api.postedSearches.size == 1) // no revoked searches sent

        optIn = true
        restartedQueue.flush()
        assertEquals(0, dao.count())
        // Advance beyond SocialScanQueue.RATE_WINDOW_MS (60s) after flushing the 55-item backlog (> 30/min cap).
        val postBacklogNow = System.currentTimeMillis() + SocialScanQueue.RATE_WINDOW_MS + 10_000L
        assertTrue(restartedQueue.enqueueForFlush(app = "youtube", contact = null, text = "re-enabled query", nowMs = postBacklogNow, source = ScanQueuePolicy.SOURCE_SEARCH))
        restartedQueue.flush()
        assertEquals(2, api.postedSearches.size)
        assertEquals("re-enabled query", api.postedSearches.last().query)

        // 4. Consent pause & epoch transition: rows queued under revoked epoch never upload after re-grant.
        assertTrue(restartedQueue.enqueueForFlush(app = "google", contact = null, text = "pre-revoke search", nowMs = postBacklogNow + 300, source = ScanQueuePolicy.SOURCE_SEARCH))
        assertTrue(restartedQueue.enqueueForFlush(app = "whatsapp", contact = "Alex", text = "pre-revoke chat", nowMs = postBacklogNow + 301, source = ScanQueuePolicy.SOURCE_SCREEN))
        paused = true
        epoch = 1L
        val sentBeforePause = api.postedSearches.size
        val socialBeforePause = api.postedSocialBatches.sumOf { it.items.size }
        assertFalse(restartedQueue.enqueueForFlush(app = "google", contact = null, text = "paused search", nowMs = postBacklogNow + 350, source = ScanQueuePolicy.SOURCE_SEARCH))
        restartedQueue.flush()
        assertEquals(sentBeforePause, api.postedSearches.size)
        assertEquals(socialBeforePause, api.postedSocialBatches.sumOf { it.items.size })

        resumedAtMs = postBacklogNow + 400
        paused = false
        assertTrue(restartedQueue.enqueueForFlush(app = "google", contact = null, text = "post-regrant search", nowMs = postBacklogNow + 450, source = ScanQueuePolicy.SOURCE_SEARCH))
        restartedQueue.flush()
        assertEquals(0, dao.count())
        assertEquals(sentBeforePause + 1, api.postedSearches.size)
        assertEquals("post-regrant search", api.postedSearches.last().query)
        assertEquals(socialBeforePause, api.postedSocialBatches.sumOf { it.items.size })
    }

    @Test
    fun `delayed flush job completes end-to-end for enqueue and enqueueSearch without self-cancelling`() = runBlocking {
        val dao = FakePendingScanDao()
        val api = FakeSearchApi()
        var storedEpoch: Long? = null
        val testScope = CoroutineScope(SupervisorJob() + Dispatchers.Default)
        try {
            val queue = SocialScanQueue(
                api = api,
                dao = dao,
                childIdProvider = { "child-1" },
                deviceIdProvider = { "dev-1" },
                allowlistProvider = { emptyList() },
                searchMonitoringEnabledProvider = { true },
                consentPausedProvider = { false },
                consentEpochProvider = { 0L },
                consentResumedAtProvider = { 0L },
                getStoredConsentEpoch = { storedEpoch },
                setStoredConsentEpoch = { storedEpoch = it },
                retryScheduler = {},
                scope = testScope,
                flushDelayMs = 40L,
            )

            queue.enqueue(app = "whatsapp", contact = "Alex", text = "delayed social msg", nowMs = System.currentTimeMillis())
            queue.enqueueSearch(engine = "google", query = "delayed search query", nowMs = System.currentTimeMillis())

            withTimeout(5_000L) {
                while (dao.count() > 0 || api.postedSocialBatches.isEmpty() || api.postedSearches.isEmpty()) {
                    delay(20L)
                }
            }
            assertEquals("delayed search query", api.postedSearches.single().query)
            assertEquals("delayed social msg", api.postedSocialBatches.single().items.single().text)
            assertEquals("dev-1", api.postedSocialBatches.single().deviceId)
        } finally {
            testScope.cancel()
        }
    }

    @Test
    fun `osra-security#56 unknown prior epoch leaves epoch unset on enqueue and aborts uploads if cleanup fails`() = runBlocking {
        val dao = FakePendingScanDao()
        val api = FakeSearchApi()
        var storedEpoch: Long? = null
        val epoch = 1L
        val resumedAtMs = System.currentTimeMillis()

        // Pre-existing capture queued before a persisted epoch existed.
        dao.insert(PendingScanEntity(app = "google", contact = null, text = "pre-grant search", source = ScanQueuePolicy.SOURCE_SEARCH, createdAt = resumedAtMs - 1_000L))
        dao.insert(PendingScanEntity(app = "whatsapp", contact = "Alex", text = "pre-grant chat", source = ScanQueuePolicy.SOURCE_SCREEN, createdAt = resumedAtMs - 500L))

        val queue = SocialScanQueue(
            api = api,
            dao = dao,
            childIdProvider = { "child-1" },
            deviceIdProvider = { "dev-1" },
            allowlistProvider = { emptyList() },
            searchMonitoringEnabledProvider = { true },
            consentPausedProvider = { false },
            consentEpochProvider = { epoch },
            consentResumedAtProvider = { resumedAtMs },
            getStoredConsentEpoch = { storedEpoch },
            setStoredConsentEpoch = { storedEpoch = it },
            retryScheduler = {},
        )

        // Enqueueing while storedEpoch is null must not stamp storedEpoch ahead of backlog cleanup.
        assertTrue(queue.enqueueForFlush(app = "google", contact = null, text = "post-grant search", nowMs = resumedAtMs + 100L, source = ScanQueuePolicy.SOURCE_SEARCH))
        assertEquals(null, storedEpoch)
        assertEquals(3, dao.count())

        // Simulated deleteBefore cleanup failure must prevent epoch advancement and all uploads.
        dao.failDeleteBefore = true
        queue.flush()
        assertEquals(null, storedEpoch)
        assertTrue("cleanup failure must block search uploads", api.postedSearches.isEmpty())
        assertTrue("cleanup failure must block social uploads", api.postedSocialBatches.isEmpty())
        assertEquals(3, dao.count())

        // Once cleanup succeeds, pre-grant rows are purged, epoch advances, and only post-grant capture uploads.
        dao.failDeleteBefore = false
        queue.flush()
        assertEquals(1L, storedEpoch)
        assertEquals(0, dao.count())
        assertEquals("post-grant search", api.postedSearches.single().query)
        assertTrue(api.postedSocialBatches.isEmpty())
    }
}
