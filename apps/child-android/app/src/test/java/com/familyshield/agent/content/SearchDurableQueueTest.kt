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
 * Contract tests for `osra-security#45`:
 * - default-off (`absent` / `null` / `false`) and revoked `searchMonitoring` opt-in
 * - minimal payload (`SearchEventDto` & `ParsedSearch` drop URL data)
 * - durable `pending_scans` queue delivery and process-restart recovery.
 */
class SearchDurableQueueTest {

    private class FakePendingScanDao : PendingScanDao {
        private var nextId = 1L
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
    }

    private class FakeSearchApi : ApiService {
        var offline = false
        val postedSearches = mutableListOf<SearchEventDto>()

        override suspend fun postSearchEvent(event: SearchEventDto) {
            if (offline) throw IOException("network unavailable")
            postedSearches.add(event)
        }

        override suspend fun postSocialScanBatch(batch: SocialScanBatchDto): SocialScanBatchResultDto =
            SocialScanBatchResultDto()

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
    fun `durable queue rejects absent opt-in, recovers across restart when enabled, and purges if revoked`() = runBlocking {
        val dao = FakePendingScanDao()
        val api = FakeSearchApi()
        var optIn = false
        var retryCount = 0

        fun newQueueInstance(): SocialScanQueue = SocialScanQueue(
            api = api,
            dao = dao,
            childIdProvider = { "child-1" },
            deviceIdProvider = { "dev-1" },
            allowlistProvider = { emptyList() },
            searchMonitoringEnabledProvider = { optIn },
            retryScheduler = { retryCount++ },
        )

        // 1. Absent/disabled opt-in: enqueue refuses cleanly.
        val q1 = newQueueInstance()
        assertFalse(q1.enqueueForFlush(app = "google", contact = null, text = "science fair", nowMs = 1_000L, source = ScanQueuePolicy.SOURCE_SEARCH))
        assertEquals(0, dao.count())

        // 2. Opt-in enabled while offline: durable row persists with attempts bumped and retry scheduled.
        optIn = true
        api.offline = true
        assertTrue(q1.enqueueForFlush(app = "google", contact = null, text = "science fair", nowMs = System.currentTimeMillis(), source = ScanQueuePolicy.SOURCE_SEARCH))
        assertEquals(1, dao.count())
        assertEquals(ScanQueuePolicy.SOURCE_SEARCH, dao.rows.single().source)

        q1.flush()
        assertTrue(api.postedSearches.isEmpty())
        assertEquals(1, dao.count())
        assertEquals(1, dao.rows.single().attempts)
        assertEquals(1, retryCount)

        // 3. Simulated process restart with fresh SocialScanQueue over the same DAO while online: delivers minimal query.
        api.offline = false
        val restartedQueue = newQueueInstance()
        restartedQueue.flush()
        assertEquals(0, dao.count())
        assertEquals(1, api.postedSearches.size)
        val sent = api.postedSearches.single()
        assertEquals("child-1", sent.childId)
        assertEquals("dev-1", sent.deviceId)
        assertEquals("google", sent.engine)
        assertEquals("science fair", sent.query)

        // 4. Opt-in revoked before flush after restart: deletes queued search row without posting.
        assertTrue(restartedQueue.enqueueForFlush(app = "youtube", contact = null, text = "coding tutorial", nowMs = System.currentTimeMillis(), source = ScanQueuePolicy.SOURCE_SEARCH))
        assertEquals(1, dao.count())
        optIn = false
        val postRevokeQueue = newQueueInstance()
        postRevokeQueue.flush()
        assertEquals(0, dao.count())
        assertEquals(1, api.postedSearches.size)
    }
}
