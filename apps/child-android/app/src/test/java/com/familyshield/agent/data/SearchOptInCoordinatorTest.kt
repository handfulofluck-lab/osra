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
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import retrofit2.Response

/**
 * Production state-persistence & missed-opt-out invalidation tests for [SearchOptInCoordinator]
 * wired to [SocialScanQueue] (`osra-security#59`).
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

    private class RecordingSearchApi : ApiService {
        val postedSearches = ArrayList<SearchEventDto>()

        override suspend fun postSearchEvent(event: SearchEventDto) {
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

    private fun rules(version: Int, searchMonitoring: Boolean?): RuleSetDto = RuleSetDto(
        rulesVersion = version,
        screenTime = ScreenTimeRuleDto(),
        searchMonitoring = searchMonitoring,
    )

    private fun buildQueue(
        coordinator: SearchOptInCoordinator,
        activeRules: () -> RuleSetDto?,
        stateDao: FakeAgentStateDao,
        scanDao: FakeScanDao,
        api: ApiService,
    ): SocialScanQueue = SocialScanQueue(
        api = api,
        dao = scanDao,
        childIdProvider = { "child-1" },
        deviceIdProvider = { "dev-1" },
        allowlistProvider = { emptyList() },
        searchMonitoringEnabledProvider = { coordinator.isSearchMonitoringEnabled(activeRules()) },
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
        retryScheduler = {},
    )

    @Test
    fun `failing DAO write on any transition key blocks search capture until persistence commits`() = runBlocking {
        val stateKeys = listOf(
            RuleRepository.KEY_SEARCH_PURGE_PENDING,
            RuleRepository.KEY_SEARCH_OPT_IN_REV,
            RuleRepository.KEY_SEARCH_OPT_IN_ENABLED,
            RuleRepository.KEY_SEARCH_RULES_VERSION,
        )

        for ((idx, failingKey) in stateKeys.withIndex()) {
            val stateDao = FakeAgentStateDao()
            val scanDao = FakeScanDao()
            val api = RecordingSearchApi()
            val coordinator = SearchOptInCoordinator(stateDao, scanDao)
            var cached: RuleSetDto? = null
            val queue = buildQueue(coordinator, { cached }, stateDao, scanDao, api)

            // Failing any single key during opt-in transition keeps search transmission disabled.
            stateDao.failOnKey = failingKey
            val grantV1 = rules(version = 10 + idx, searchMonitoring = true)
            coordinator.onRulesFetched(previous = null, updated = grantV1)
            cached = grantV1
            assertFalse("enable with failing $failingKey must stay disabled", coordinator.isSearchMonitoringEnabled(cached))
            assertEquals("enable with failing $failingKey must keep rev=0", 0L, coordinator.currentRevision())
            assertFalse(queue.enqueueForFlush("google", null, "blocked on $failingKey", 1_000L, ScanQueuePolicy.SOURCE_SEARCH))
            queue.flush()
            assertTrue(api.postedSearches.isEmpty())

            // Recovery succeeds once DAO write works.
            stateDao.failOnKey = null
            coordinator.onRulesFetched(previous = cached, updated = grantV1)
            assertTrue(coordinator.isSearchMonitoringEnabled(cached))
            val rev1 = coordinator.currentRevision()
            assertTrue(rev1 > 0L)
            assertTrue(queue.enqueueForFlush("google", null, "committed query", 2_000L, ScanQueuePolicy.SOURCE_SEARCH))

            // Failing any single key during opt-out still disqualifies in-memory search capture immediately and blocks uploads.
            stateDao.failOnKey = failingKey
            val optOutV2 = rules(version = 20 + idx, searchMonitoring = false)
            coordinator.onRulesFetched(previous = cached, updated = optOutV2)
            assertFalse("opt-out with failing $failingKey must disqualify search capture", coordinator.isSearchMonitoringEnabled(cached))
            assertEquals("opt-out with failing $failingKey must invalidate rev", 0L, coordinator.currentRevision())
            queue.flush()
            assertTrue("opt-out with failing $failingKey must block upload", api.postedSearches.isEmpty())

            // Once persistence recovers, opt-out purges pre-opt-out queued rows cleanly.
            stateDao.failOnKey = null
            coordinator.onRulesFetched(previous = cached, updated = optOutV2)
            cached = optOutV2
            assertFalse(coordinator.isSearchMonitoringEnabled(cached))
            assertEquals(0, scanDao.count())
        }
    }

    @Test
    fun `missed offline opt-out on newer rulesVersion rotates revision and invalidates stale queued searches`() = runBlocking {
        val stateDao = FakeAgentStateDao()
        val scanDao = FakeScanDao()
        val api = RecordingSearchApi()
        val coordinator = SearchOptInCoordinator(stateDao, scanDao)
        var cached: RuleSetDto? = null
        val queue = buildQueue(coordinator, { cached }, stateDao, scanDao, api)
        val baseNow = System.currentTimeMillis()

        // Device syncs v10 (searchMonitoring=true) and queues a search while offline.
        val grantV10 = rules(version = 10, searchMonitoring = true)
        coordinator.onRulesFetched(previous = null, updated = grantV10)
        cached = grantV10
        assertTrue(coordinator.isSearchMonitoringEnabled(cached))
        val rev10 = coordinator.currentRevision()
        assertTrue(queue.enqueueForFlush("google", null, "before offline opt-out", baseNow, ScanQueuePolicy.SOURCE_SEARCH))
        assertEquals(1, scanDao.count())

        // While offline, parent toggled searchMonitoring false (v11) and back true (v12).
        // Next sync jumps directly from v10(true) -> v12(true): must conservatively rotate rev and purge v10 rows.
        val grantV12 = rules(version = 12, searchMonitoring = true)
        coordinator.onRulesFetched(previous = cached, updated = grantV12)
        cached = grantV12
        assertTrue(coordinator.isSearchMonitoringEnabled(cached))
        val rev12 = coordinator.currentRevision()
        assertTrue(rev12 > rev10)
        assertEquals("v10 pre-optout row must be purged on rulesVersion advance", 0, scanDao.count())

        // Even if deleteStaleSearches failed during transition, row tagged rev10 still cannot flush under rev12.
        scanDao.insert(
            PendingScanEntity(
                app = "google",
                contact = null,
                text = "stray v10 row",
                source = ScanQueuePolicy.searchSource(rev10),
                createdAt = baseNow + 1_000L,
            ),
        )
        queue.flush()
        assertTrue("row from prior rulesVersion cannot upload after re-enable", api.postedSearches.isEmpty())

        // Same rulesVersion restart reload preserves committed rev12, and fresh captures flush cleanly.
        val reloaded = SearchOptInCoordinator(stateDao, scanDao)
        reloaded.onStartupLoaded(grantV12)
        assertTrue(reloaded.isSearchMonitoringEnabled(grantV12))
        assertEquals(rev12, reloaded.currentRevision())

        assertTrue(queue.enqueueForFlush("bing", null, "post re-enable query", baseNow + 2_000L, ScanQueuePolicy.SOURCE_SEARCH))
        queue.flush()
        assertEquals(listOf("post re-enable query"), api.postedSearches.map { it.query })
    }

    @Test
    fun `startup read failure and forgetRules keep search capture disabled`() = runBlocking {
        val stateDao = FakeAgentStateDao()
        val scanDao = FakeScanDao()
        val coordinator = SearchOptInCoordinator(stateDao, scanDao)
        val grantV10 = rules(version = 10, searchMonitoring = true)
        coordinator.onRulesFetched(previous = null, updated = grantV10)
        assertTrue(coordinator.isSearchMonitoringEnabled(grantV10))

        // Unlink / forgetRules disables capture and rotates/purges durable state.
        coordinator.onForgetRules()
        assertFalse(coordinator.isSearchMonitoringEnabled(grantV10))
        assertEquals(0L, coordinator.currentRevision())
        assertEquals(0L, stateDao.state[RuleRepository.KEY_SEARCH_OPT_IN_ENABLED])

        // Cold startup where AgentStateDao read fails stays disabled even if cached disk rules had searchMonitoring=true.
        val restarting = SearchOptInCoordinator(stateDao, scanDao)
        stateDao.failReads = true
        restarting.onStartupLoaded(grantV10)
        assertFalse(restarting.isSearchMonitoringEnabled(grantV10))
        assertEquals(0L, restarting.currentRevision())
    }
}
