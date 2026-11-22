package com.familyshield.agent

import android.content.Context
import com.familyshield.agent.data.AgentSettings
import com.familyshield.agent.data.RuleRepository
import com.familyshield.agent.data.db.PendingScanDao
import com.familyshield.agent.data.db.PendingScanEntity
import com.familyshield.agent.network.ApiService
import com.familyshield.agent.network.dto.SocialScanBatchDto
import com.familyshield.agent.network.dto.SocialScanBatchResultDto
import com.familyshield.agent.network.dto.SocialScanItemResultDto
import com.familyshield.agent.social.SocialScanQueue
import kotlinx.coroutines.awaitCancellation
import kotlinx.coroutines.cancelAndJoin
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import kotlinx.coroutines.yield
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import org.mockito.Mockito

/**
 * Mutants: restoring unconditional `flushJob?.cancel()` makes the delayed row time out before its POST;
 * swallowing `CancellationException` from the DAO can make the caller finish as though the queue were empty.
 */
class SocialScanQueueFlushTest {
    @Test
    fun `delayed enqueue uploads and deletes the durable row`() = runBlocking {
        val dao = FakePendingScanDao()
        val posts = mutableListOf<SocialScanBatchDto>()
        val queue = queue(dao, posts)

        queue.enqueue("whatsapp", null, "synthetic scan fixture", nowMs = System.currentTimeMillis())

        withTimeout(7_000) {
            while (posts.isEmpty()) delay(25)
        }
        withTimeout(2_000) {
            while (dao.rows().isNotEmpty()) delay(25)
        }
        assertEquals(1, posts.size)
        assertEquals(1, posts.single().items.size)
        assertEquals("child", posts.single().items.single().childId)
        assertEquals(emptyList<PendingScanEntity>(), dao.rows())
    }

    @Test
    fun `caller cancellation leaves the row queued instead of looking empty`() = runBlocking {
        val dao = FakePendingScanDao(
            initialRows = listOf(scan()),
            suspendOldest = true,
        )
        val posts = mutableListOf<SocialScanBatchDto>()
        val queue = queue(dao, posts)

        val caller = launch { queue.flush() }
        yield()
        caller.cancelAndJoin()

        assertTrue(caller.isCancelled)
        assertEquals(0, posts.size)
        assertEquals(1, dao.rows().size)
        assertEquals(0, dao.rows().single().attempts)
    }

    private fun queue(dao: PendingScanDao, posts: MutableList<SocialScanBatchDto>): SocialScanQueue {
        val api = Mockito.mock(
            ApiService::class.java,
            Mockito.withSettings().defaultAnswer { invocation ->
                if (invocation.method.name != "postSocialScanBatch") {
                    throw UnsupportedOperationException(invocation.method.name)
                }
                val batch = invocation.getArgument<SocialScanBatchDto>(0)
                posts += batch
                SocialScanBatchResultDto(batch.items.map { SocialScanItemResultDto(ok = true) })
            },
        )
        val settings = Mockito.mock(AgentSettings::class.java)
        val rules = Mockito.mock(RuleRepository::class.java)
        val context = Mockito.mock(Context::class.java)
        return runBlocking {
            Mockito.`when`(settings.childId()).thenReturn("child")
            Mockito.`when`(settings.deviceId()).thenReturn("device")
            SocialScanQueue(api, settings, rules, dao, context)
        }
    }

    private class FakePendingScanDao(
        initialRows: List<PendingScanEntity> = emptyList(),
        private val suspendOldest: Boolean = false,
    ) : PendingScanDao {
        private val data = initialRows.toMutableList()
        private var nextId = initialRows.maxOfOrNull { it.id }?.plus(1) ?: 1

        override suspend fun insert(scan: PendingScanEntity): Long {
            yield()
            val id = nextId++
            data += scan.copy(id = id)
            return id
        }

        override suspend fun oldest(limit: Int): List<PendingScanEntity> {
            if (suspendOldest) awaitCancellation()
            yield()
            return data.sortedBy { it.createdAt }.take(limit)
        }

        override suspend fun delete(id: Long) {
            yield()
            data.removeAll { it.id == id }
        }

        override suspend fun bumpAttempts(id: Long) {
            val index = data.indexOfFirst { it.id == id }
            if (index >= 0) data[index] = data[index].copy(attempts = data[index].attempts + 1)
        }

        override suspend fun count(): Int = data.size

        override suspend fun purge(olderThanMs: Long, maxAttempts: Int): Int {
            yield()
            val before = data.size
            data.removeAll { it.createdAt < olderThanMs || it.attempts >= maxAttempts }
            return before - data.size
        }

        fun rows(): List<PendingScanEntity> = data.toList()
    }

    private companion object {
        fun scan() = PendingScanEntity(
            id = 1,
            app = "whatsapp",
            contact = null,
            text = "synthetic scan fixture",
            source = "notification",
            createdAt = System.currentTimeMillis(),
        )
    }
}
