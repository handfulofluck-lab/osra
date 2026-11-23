package com.familyshield.agent

import android.content.Context
import com.familyshield.agent.data.AgentSettings
import com.familyshield.agent.data.ConsentState
import com.familyshield.agent.data.RuleRepository
import com.familyshield.agent.data.db.AgentStateDao
import com.familyshield.agent.data.db.PendingScanDao
import com.familyshield.agent.data.db.PendingScanEntity
import com.familyshield.agent.network.ApiService
import com.familyshield.agent.network.dto.SocialScanBatchDto
import com.familyshield.agent.network.dto.SocialScanBatchResultDto
import com.familyshield.agent.network.dto.SocialScanItemResultDto
import com.familyshield.agent.social.SocialScanQueue
import java.util.Collections
import java.util.concurrent.CopyOnWriteArrayList
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.awaitCancellation
import kotlinx.coroutines.cancelAndJoin
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import kotlinx.coroutines.yield
import org.junit.Assert.assertEquals
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Test
import org.mockito.Mockito

/**
 * Mutants: restoring unconditional `flushJob?.cancel()` makes the delayed row time out before its POST;
 * swallowing `CancellationException` from the DAO makes the originated-cancellation assertion fail.
 * The worker race waits beyond the original delay so a second scheduled POST cannot pass unnoticed.
 */
class SocialScanQueueFlushTest {
    @Test
    fun `delayed enqueue uploads and deletes the durable row`() = runBlocking {
        val dao = FakePendingScanDao()
        val posts = CopyOnWriteArrayList<SocialScanBatchDto>()
        val posted = CompletableDeferred<Unit>()
        val queue = queue(dao, posts, posted)

        queue.enqueue("whatsapp", null, "synthetic scan fixture", nowMs = System.currentTimeMillis())

        withTimeout(7_000) { posted.await() }
        withTimeout(2_000) { dao.deleted.await() }
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
        val posts = CopyOnWriteArrayList<SocialScanBatchDto>()
        val queue = queue(dao, posts)

        val caller = launch { queue.flush() }
        dao.oldestEntered.await()
        caller.cancelAndJoin()

        assertTrue(caller.isCancelled)
        assertEquals(0, posts.size)
        assertEquals(1, dao.rows().size)
        assertEquals(0, dao.rows().single().attempts)
    }

    @Test
    fun `DAO originated cancellation propagates and retains the row`() = runBlocking {
        val dao = FakePendingScanDao(
            initialRows = listOf(scan()),
            cancelOldest = true,
        )
        val posts = CopyOnWriteArrayList<SocialScanBatchDto>()
        val queue = queue(dao, posts)

        val error = assertThrows(CancellationException::class.java) {
            runBlocking { queue.flush() }
        }

        assertEquals("DAO cancelled", error.message)
        assertEquals(0, posts.size)
        assertEquals(1, dao.rows().size)
        assertEquals(0, dao.rows().single().attempts)
    }

    @Test
    fun `worker flush cancels delayed flush without duplicate upload`() = runBlocking {
        val dao = FakePendingScanDao()
        val posts = CopyOnWriteArrayList<SocialScanBatchDto>()
        val posted = CompletableDeferred<Unit>()
        val queue = queue(dao, posts, posted)
        queue.enqueue("whatsapp", null, "synthetic scan fixture", nowMs = System.currentTimeMillis())
        withTimeout(2_000) { dao.inserted.await() }

        queue.flush()
        assertEquals(1, posts.size)
        assertEquals(emptyList<PendingScanEntity>(), dao.rows())

        delay(SocialScanQueue.FLUSH_DELAY_MS + 500)
        assertEquals(1, posts.size)
        assertEquals(emptyList<PendingScanEntity>(), dao.rows())
    }

    private fun queue(
        dao: PendingScanDao,
        posts: MutableList<SocialScanBatchDto>,
        posted: CompletableDeferred<Unit> = CompletableDeferred(),
    ): SocialScanQueue {
        val api = Mockito.mock(
            ApiService::class.java,
            Mockito.withSettings().defaultAnswer { invocation ->
                if (invocation.method.name != "postSocialScanBatch") {
                    throw UnsupportedOperationException(invocation.method.name)
                }
                val batch = invocation.getArgument<SocialScanBatchDto>(0)
                posts += batch
                posted.complete(Unit)
                SocialScanBatchResultDto(batch.items.map { SocialScanItemResultDto(ok = true) })
            },
        )
        val settings = Mockito.mock(AgentSettings::class.java)
        val rules = Mockito.mock(RuleRepository::class.java)
        val agentStateDao = Mockito.mock(AgentStateDao::class.java)
        val consent = Mockito.mock(ConsentState::class.java)
        val context = Mockito.mock(Context::class.java)
        return runBlocking {
            Mockito.`when`(settings.childId()).thenReturn("child")
            Mockito.`when`(settings.deviceId()).thenReturn("device")
            SocialScanQueue(api, settings, rules, dao, agentStateDao, consent, context)
        }
    }

    private class FakePendingScanDao(
        initialRows: List<PendingScanEntity> = emptyList(),
        private val suspendOldest: Boolean = false,
        private val cancelOldest: Boolean = false,
    ) : PendingScanDao {
        val inserted = CompletableDeferred<Unit>()
        val deleted = CompletableDeferred<Unit>()
        val oldestEntered = CompletableDeferred<Unit>()
        private val data = Collections.synchronizedList(initialRows.toMutableList())
        private var nextId = initialRows.maxOfOrNull { it.id }?.plus(1) ?: 1

        override suspend fun insert(scan: PendingScanEntity): Long {
            yield()
            val id = synchronized(data) {
                val id = nextId++
                data += scan.copy(id = id)
                id
            }
            inserted.complete(Unit)
            return id
        }

        override suspend fun oldest(limit: Int): List<PendingScanEntity> {
            oldestEntered.complete(Unit)
            when {
                suspendOldest -> awaitCancellation()
                cancelOldest -> throw CancellationException("DAO cancelled")
            }
            yield()
            return synchronized(data) { data.sortedBy { it.createdAt }.take(limit) }
        }

        override suspend fun delete(id: Long) {
            yield()
            synchronized(data) { data.removeAll { it.id == id } }
            deleted.complete(Unit)
        }

        override suspend fun bumpAttempts(id: Long) {
            synchronized(data) {
                val index = data.indexOfFirst { it.id == id }
                if (index >= 0) data[index] = data[index].copy(attempts = data[index].attempts + 1)
            }
        }

        override suspend fun count(): Int = synchronized(data) { data.size }

        override suspend fun purge(olderThanMs: Long, maxAttempts: Int): Int {
            yield()
            return synchronized(data) {
                val before = data.size
                data.removeAll { it.createdAt < olderThanMs || it.attempts >= maxAttempts }
                before - data.size
            }
        }

        override suspend fun deleteBySource(source: String): Int = synchronized(data) {
            val before = data.size
            data.removeAll { it.source == source }
            before - data.size
        }

        override suspend fun deleteAllSearches(): Int = synchronized(data) {
            val before = data.size
            data.removeAll { it.source == "search" || it.source.startsWith("search:") }
            before - data.size
        }

        override suspend fun deleteStaleSearches(activeSource: String): Int = synchronized(data) {
            val before = data.size
            data.removeAll { (it.source == "search" || it.source.startsWith("search:")) && it.source != activeSource }
            before - data.size
        }

        override suspend fun deleteBefore(beforeMs: Long): Int = synchronized(data) {
            val before = data.size
            data.removeAll { it.createdAt < beforeMs }
            before - data.size
        }

        fun rows(): List<PendingScanEntity> = synchronized(data) { data.toList() }
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
