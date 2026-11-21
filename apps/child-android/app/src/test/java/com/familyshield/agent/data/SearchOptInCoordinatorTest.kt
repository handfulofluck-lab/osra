package com.familyshield.agent.data

import com.familyshield.agent.data.db.AgentStateDao
import com.familyshield.agent.data.db.AgentStateEntity
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
import com.familyshield.agent.network.dto.ScreenTimeRuleDto
import com.familyshield.agent.network.dto.SearchEventDto
import com.familyshield.agent.network.dto.SocialScanBatchDto
import com.familyshield.agent.network.dto.SocialScanBatchResultDto
import com.familyshield.agent.network.dto.SocialScanDto
import com.familyshield.agent.network.dto.SocialScanItemResultDto
import com.familyshield.agent.network.dto.TelemetryDto
import com.familyshield.agent.social.ScanQueuePolicy
import com.familyshield.agent.social.SocialScanQueue
import java.io.IOException
import kotlinx.coroutines.runBlocking
import okhttp3.MediaType.Companion.toMediaTypeOrNull
import okhttp3.ResponseBody.Companion.toResponseBody
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import retrofit2.HttpException
import retrofit2.Response

/**
 * Production state-persistence, startup cache isolation, and server-verified grant revision tests
 * for [SearchOptInCoordinator] wired to [SocialScanQueue] (`osra-security#59`).
 */
class SearchOptInCoordinatorTest {

    private class FakeAgentStateDao : AgentStateDao {
        val state = HashMap<String, Long>()
        var failReads = false
        var failWrites = false
        var failOnKey: String? = null

        override suspend fun get(key: String): Long? {
            if (failReads) throw IOException("simulated AgentStateDao read failure")
            return state[key]
        }

        override suspend fun set(entity: AgentStateEntity) {
            if (failWrites || entity.key == failOnKey) {
                throw IOException("simulated AgentStateDao write failure for ${entity.key}")
            }
            state[entity.key] = entity.valueLong
        }
    }

    private class FakeScanDao : PendingScanDao {
        val rows = ArrayList<PendingScanEntity>()
        var nextId = 1L
        var failDeleteSearches = false

        override suspend fun insert(scan: PendingScanEntity): Long {
            val row = scan.copy(id = nextId++)
            rows.add(row)
            return row.id
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

        override suspend fun deleteAllSearches(): Int {
            if (failDeleteSearches) throw IOException("simulated deleteAllSearches failure")
            val before = rows.size
            rows.removeAll { ScanQueuePolicy.isSearchSource(it.source) }
            return before - rows.size
        }

        override suspend fun deleteStaleSearches(activeSource: String): Int {
            if (failDeleteSearches) throw IOException("simulated deleteStaleSearches failure")
            val before = rows.size
            rows.removeAll { ScanQueuePolicy.isSearchSource(it.source) && it.source != activeSource }
            return before - rows.size
        }

        override suspend fun deleteBefore(beforeMs: Long): Int {
            val before = rows.size
            rows.removeAll { it.createdAt < beforeMs }
            return before - rows.size
        }
    }

    private class RecordingSearchApi(
        var activeServerRevision: Int = 1,
    ) : ApiService {
        val postedSearches = ArrayList<SearchEventDto>()

        override suspend fun postSearchEvent(event: SearchEventDto) {
            if (event.searchMonitoringRevision <= 0 || event.searchMonitoringRevision != activeServerRevision) {
                val body = """{"error":"stale_search_grant"}""".toResponseBody("application/json".toMediaTypeOrNull())
                throw HttpException(Response.error<Unit>(409, body))
            }
            postedSearches.add(event)
        }

        override suspend fun postSocialScanBatch(batch: SocialScanBatchDto): SocialScanBatchResultDto =
            SocialScanBatchResultDto(batch.items.map { SocialScanItemResultDto(ok = true) })

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

    private fun rules(version: Int, searchMonitoring: Boolean?, searchMonitoringRevision: Int): RuleSetDto = RuleSetDto(
        rulesVersion = version,
        screenTime = ScreenTimeRuleDto(),
        searchMonitoring = searchMonitoring,
        searchMonitoringRevision = searchMonitoringRevision,
    )

    private fun buildQueue(
        coordinator: SearchOptInCoordinator,
        activeRules: () -> RuleSetDto?,
        stateDao: FakeAgentStateDao,
        scanDao: FakeScanDao,
        api: ApiService,
        onRetry: () -> Unit = {},
    ): SocialScanQueue = SocialScanQueue(
        api = api,
        dao = scanDao,
        childIdProvider = { "child-1" },
        deviceIdProvider = { "dev-1" },
        allowlistProvider = { emptyList() },
        searchMonitoringEnabledProvider = { coordinator.isSearchMonitoringEnabled(activeRules()) },
        searchSyncConfirmedProvider = { coordinator.isFreshSyncConfirmed() },
        searchOptInRevisionProvider = { coordinator.currentRevision() },
        getSearchPurgePending = { (stateDao.state[RuleRepository.KEY_SEARCH_PURGE_PENDING] ?: 0L) != 0L },
        setSearchPurgePending = { pending ->
            stateDao.set(AgentStateEntity(RuleRepository.KEY_SEARCH_PURGE_PENDING, if (pending) 1L else 0L))
        },
        consentPausedProvider = { false },
        consentEpochProvider = { 0L },
        consentResumedAtProvider = { 0L },
        getStoredConsentEpoch = { 0L },
        setStoredConsentEpoch = {},
        retryScheduler = onRetry,
    )

    @Test
    fun `failing DAO write on any transition key blocks search capture until persistence commits`() = runBlocking {
        val stateKeys = listOf(
            RuleRepository.KEY_SEARCH_PURGE_PENDING,
            RuleRepository.KEY_SEARCH_OPT_IN_REV,
            RuleRepository.KEY_SEARCH_OPT_IN_ENABLED,
            RuleRepository.KEY_SEARCH_RULES_VERSION,
        )
        val baseNow = System.currentTimeMillis()

        for ((idx, failingKey) in stateKeys.withIndex()) {
            val stateDao = FakeAgentStateDao()
            val scanDao = FakeScanDao()
            val serverRev = idx + 1
            val api = RecordingSearchApi(activeServerRevision = serverRev)
            val coordinator = SearchOptInCoordinator(stateDao, scanDao)
            var cached: RuleSetDto? = null
            val queue = buildQueue(coordinator, { cached }, stateDao, scanDao, api)

            // Failing any single key during opt-in transition keeps search transmission disabled.
            stateDao.failOnKey = failingKey
            val grant = rules(version = 10 + idx, searchMonitoring = true, searchMonitoringRevision = serverRev)
            coordinator.onRulesFetched(previous = null, updated = grant)
            cached = grant
            assertFalse("enable with failing $failingKey must stay disabled", coordinator.isSearchMonitoringEnabled(cached))
            assertEquals("enable with failing $failingKey must keep rev=0", 0L, coordinator.currentRevision())
            assertFalse(queue.enqueueForFlush("google", null, "blocked on $failingKey", baseNow, ScanQueuePolicy.SOURCE_SEARCH))
            queue.flush()
            assertTrue(api.postedSearches.isEmpty())

            // Recovery succeeds once DAO write works.
            stateDao.failOnKey = null
            coordinator.onRulesFetched(previous = cached, updated = grant)
            assertTrue(coordinator.isSearchMonitoringEnabled(cached))
            assertEquals(serverRev.toLong(), coordinator.currentRevision())
            assertTrue(queue.enqueueForFlush("google", null, "committed query", baseNow + 100L, ScanQueuePolicy.SOURCE_SEARCH))

            // Failing any single key during opt-out still disqualifies in-memory search capture immediately and blocks uploads.
            stateDao.failOnKey = failingKey
            val optOut = rules(version = 20 + idx, searchMonitoring = false, searchMonitoringRevision = serverRev + 1)
            coordinator.onRulesFetched(previous = cached, updated = optOut)
            assertFalse("opt-out with failing $failingKey must disqualify search capture", coordinator.isSearchMonitoringEnabled(cached))
            assertEquals("opt-out with failing $failingKey must invalidate rev", 0L, coordinator.currentRevision())
            queue.flush()
            assertTrue("opt-out with failing $failingKey must block upload", api.postedSearches.isEmpty())

            // Once persistence recovers, opt-out purges pre-opt-out queued rows cleanly.
            stateDao.failOnKey = null
            coordinator.onRulesFetched(previous = cached, updated = optOut)
            cached = optOut
            assertFalse(coordinator.isSearchMonitoringEnabled(cached))
            assertEquals(0, scanDao.count())
        }
    }

    @Test
    fun `cached startup disk rules never enable capture or unverified uploads before server sync`() = runBlocking {
        val stateDao = FakeAgentStateDao()
        val scanDao = FakeScanDao()
        val api = RecordingSearchApi(activeServerRevision = 3) // Server moved offline rev 1 -> 2(off) -> 3(on)
        val coordinator = SearchOptInCoordinator(stateDao, scanDao)
        val cachedDiskV1 = rules(version = 10, searchMonitoring = true, searchMonitoringRevision = 1)
        val baseNow = System.currentTimeMillis()
        var retries = 0

        // Simulate pre-existing queued row from rev 1 before process restart.
        scanDao.insert(
            PendingScanEntity(
                app = "google",
                contact = null,
                text = "pre-restart rev1 query",
                source = ScanQueuePolicy.searchSource(1L),
                createdAt = baseNow,
            ),
        )

        // RuleRepository.kt:97 startup disk load restores cachedDiskV1 without live server sync.
        coordinator.onStartupLoaded(cachedDiskV1)
        assertFalse("startup disk rules alone must not confirm fresh server sync", coordinator.isFreshSyncConfirmed())
        assertFalse("startup disk rules alone must not enable search capture", coordinator.isSearchMonitoringEnabled(cachedDiskV1))
        assertEquals(0L, coordinator.currentRevision())

        val queue = buildQueue(coordinator, { cachedDiskV1 }, stateDao, scanDao, api) { retries++ }
        // Enqueueing and worker flush BEFORE live server sync must refuse capture and hold without uploading.
        assertFalse(queue.enqueueForFlush("google", null, "blocked before sync", baseNow + 100L, ScanQueuePolicy.SOURCE_SEARCH))
        queue.flush()
        assertTrue("worker runnable at startup before refresh must not upload unverified searches", api.postedSearches.isEmpty())
        assertEquals(1, retries)

        // Live server sync arrives at rev 3 (after missed offline opt-out): purges stale rev 1 row cleanly.
        val syncedV3 = rules(version = 12, searchMonitoring = true, searchMonitoringRevision = 3)
        coordinator.onRulesFetched(previous = cachedDiskV1, updated = syncedV3)
        assertTrue(coordinator.isFreshSyncConfirmed())
        assertTrue(coordinator.isSearchMonitoringEnabled(syncedV3))
        assertEquals(3L, coordinator.currentRevision())
        assertEquals("rev-1 row must be purged once server rev 3 syncs", 0, scanDao.count())
    }

    @Test
    fun `refused server upload due to stale searchMonitoringRevision is purged without retry`() = runBlocking {
        val stateDao = FakeAgentStateDao()
        val scanDao = FakeScanDao()
        val api = RecordingSearchApi(activeServerRevision = 1)
        val coordinator = SearchOptInCoordinator(stateDao, scanDao)
        val grantRev1 = rules(version = 10, searchMonitoring = true, searchMonitoringRevision = 1)
        coordinator.onRulesFetched(previous = null, updated = grantRev1)

        var retries = 0
        val queue = buildQueue(coordinator, { grantRev1 }, stateDao, scanDao, api) { retries++ }
        val baseNow = System.currentTimeMillis()
        assertTrue(queue.enqueueForFlush("google", null, "rev1 search before offline opt-out", baseNow, ScanQueuePolicy.SOURCE_SEARCH))

        // Server moved to rev 3 (off -> on offline) before device refreshed again.
        api.activeServerRevision = 3
        queue.flush()

        assertTrue("server must refuse stale rev 1 row", api.postedSearches.isEmpty())
        assertEquals("refused 409 row must be purged from queue immediately", 0, scanDao.count())
        assertEquals("refused 409 row must not be retried", 0, retries)
    }

    @Test
    fun `forgetRules disables search capture and purges durable state`() = runBlocking {
        val stateDao = FakeAgentStateDao()
        val scanDao = FakeScanDao()
        val coordinator = SearchOptInCoordinator(stateDao, scanDao)
        val grantV10 = rules(version = 10, searchMonitoring = true, searchMonitoringRevision = 2)
        coordinator.onRulesFetched(previous = null, updated = grantV10)
        assertTrue(coordinator.isSearchMonitoringEnabled(grantV10))

        coordinator.onForgetRules()
        assertFalse(coordinator.isSearchMonitoringEnabled(grantV10))
        assertEquals(0L, coordinator.currentRevision())
        assertEquals(0L, stateDao.state[RuleRepository.KEY_SEARCH_OPT_IN_ENABLED])
    }
}
