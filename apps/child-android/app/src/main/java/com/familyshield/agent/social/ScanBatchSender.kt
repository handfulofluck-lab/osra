package com.familyshield.agent.social

import com.familyshield.agent.network.dto.SocialScanDto
import com.familyshield.agent.network.dto.SocialScanItemResultDto
import kotlinx.coroutines.CancellationException

/**
 * #490: sends a flush as requests of up to [ScanQueuePolicy.ITEMS_PER_REQUEST] captures instead of one
 * request per row, and sorts each row by its own answer. Pure apart from [post], so a JVM row can count
 * the calls.
 *
 * - **sent**: the server answered `ok` for the row; the queue deletes it.
 * - **rejected**: the server answered for the row and will not take it (`ok: false`, or a 4xx other than
 *   429 for the whole request); the queue counts it down towards the drop.
 * - **failed**: no usable answer (network, 5xx, 429, or a reply whose length does not match the
 *   request); the queue keeps it and schedules a retry.
 */
class ScanBatchSender<R>(
    private val toDto: (R) -> SocialScanDto,
    private val post: suspend (List<SocialScanDto>) -> List<SocialScanItemResultDto>,
    private val isPermanentRejection: (Throwable) -> Boolean,
) {
    data class Outcome<R>(val sent: List<R>, val rejected: List<R>, val failed: List<R>)

    suspend fun send(rows: List<R>): Outcome<R> {
        val sent = mutableListOf<R>()
        val rejected = mutableListOf<R>()
        val failed = mutableListOf<R>()
        for (chunk in rows.chunked(ScanQueuePolicy.ITEMS_PER_REQUEST)) {
            val answer = try {
                Result.success(post(chunk.map(toDto)))
            } catch (e: CancellationException) {
                throw e
            } catch (e: Throwable) {
                Result.failure(e)
            }
            val results = answer.getOrNull()
            when {
                results != null && results.size == chunk.size ->
                    chunk.zip(results).forEach { (row, r) -> if (r.ok) sent += row else rejected += row }
                results != null -> failed += chunk // a reply that does not line up with the request
                isPermanentRejection(answer.exceptionOrNull()!!) -> rejected += chunk
                else -> failed += chunk
            }
        }
        return Outcome(sent, rejected, failed)
    }
}
