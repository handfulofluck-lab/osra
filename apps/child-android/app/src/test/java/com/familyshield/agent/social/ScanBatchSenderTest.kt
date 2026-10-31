package com.familyshield.agent.social

import com.familyshield.agent.network.dto.SocialScanDto
import com.familyshield.agent.network.dto.SocialScanItemResultDto
import java.io.File
import java.io.IOException
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * #490 (Flip4, #484 row I1): a flush of six captures went out as six `POST /v1/social/scan`, waking the
 * radio six times where once would do. The sender now posts up to ITEMS_PER_REQUEST captures per call
 * and settles each row by its own answer.
 *
 * Mutants: send per row again (`chunked(1)`) → [a batch of six is one call] goes red; put the old
 * per-row `postSocialScan` loop back in `flush()` → [the queue flushes through the batch sender] goes red.
 */
class ScanBatchSenderTest {

    private fun dto(text: String) = SocialScanDto(childId = "c", deviceId = "d", app = "whatsapp", text = text)

    private fun sender(
        calls: MutableList<List<SocialScanDto>>,
        answer: (List<SocialScanDto>) -> List<SocialScanItemResultDto>,
        permanent: (Throwable) -> Boolean = { false },
    ) = ScanBatchSender<String>(
        toDto = ::dto,
        post = { items -> calls += items; answer(items) },
        isPermanentRejection = permanent,
    )

    @Test
    fun `a batch of six is one call`() = runBlocking {
        val calls = mutableListOf<List<SocialScanDto>>()
        val rows = List(6) { "m$it" }
        val out = sender(calls, { items -> items.map { SocialScanItemResultDto(ok = true) } }).send(rows)
        assertEquals("six captures, one request", 1, calls.size)
        assertEquals(6, calls[0].size)
        assertEquals(rows, out.sent)
    }

    @Test
    fun `a larger flush goes out six at a time, never more`() = runBlocking {
        val calls = mutableListOf<List<SocialScanDto>>()
        sender(calls, { items -> items.map { SocialScanItemResultDto(ok = true) } }).send(List(13) { "m$it" })
        assertEquals(listOf(6, 6, 1), calls.map { it.size })
        assertTrue(calls.all { it.size <= ScanQueuePolicy.ITEMS_PER_REQUEST })
    }

    @Test
    fun `only the rows the server took are sent, and the refused one is counted down`() = runBlocking {
        val calls = mutableListOf<List<SocialScanDto>>()
        val out = sender(calls, { items ->
            items.map {
                if (it.text == "m1") SocialScanItemResultDto(ok = false, reason = "invalid_item") else SocialScanItemResultDto(ok = true)
            }
        }).send(listOf("m0", "m1", "m2"))
        assertEquals(listOf("m0", "m2"), out.sent)
        assertEquals(listOf("m1"), out.rejected)
        assertTrue(out.failed.isEmpty())
    }

    @Test
    fun `a network failure keeps every row of the request`() = runBlocking {
        val calls = mutableListOf<List<SocialScanDto>>()
        val out = sender(calls, { throw IOException("offline") }).send(listOf("m0", "m1", "m2"))
        assertTrue(out.sent.isEmpty())
        assertEquals(listOf("m0", "m1", "m2"), out.failed)
    }

    @Test
    fun `a permanent rejection of the whole request counts every row down`() = runBlocking {
        val calls = mutableListOf<List<SocialScanDto>>()
        val out = sender(calls, { throw IllegalStateException("400") }, permanent = { true }).send(listOf("m0", "m1"))
        assertEquals(listOf("m0", "m1"), out.rejected)
        assertTrue(out.failed.isEmpty())
    }

    @Test
    fun `a reply that does not line up with the request deletes nothing`() = runBlocking {
        val calls = mutableListOf<List<SocialScanDto>>()
        val out = sender(calls, { listOf(SocialScanItemResultDto(ok = true)) }).send(listOf("m0", "m1"))
        assertTrue("a short reply must not be read as acks for the first rows", out.sent.isEmpty())
        assertEquals(listOf("m0", "m1"), out.failed)
    }

    @Test
    fun `the request size matches the server's limit`() {
        assertEquals("services/api SCAN_BATCH_MAX", 6, ScanQueuePolicy.ITEMS_PER_REQUEST)
    }

    @Test
    fun `the queue flushes through the batch sender, not one call per row`() {
        var dir: File? = File(System.getProperty("user.dir")).absoluteFile
        var file: File? = null
        while (dir != null && file == null) {
            file = File(dir, "app/src/main/java/com/familyshield/agent/social/SocialScanQueue.kt").takeIf { it.isFile }
            dir = dir.parentFile
        }
        val flush = requireNotNull(file).readText().substringAfter("suspend fun flush()").substringBefore("suspend fun pendingCount()")
        assertTrue("flush sends through ScanBatchSender", flush.contains("ScanBatchSender<"))
        assertTrue("with the batch endpoint", flush.contains("api.postSocialScanBatch("))
        assertTrue("and no longer per row", !flush.contains("api.postSocialScan("))
    }
}
