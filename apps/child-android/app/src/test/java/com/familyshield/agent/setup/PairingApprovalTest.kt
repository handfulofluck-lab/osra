package com.familyshield.agent.setup

import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.IOException

/**
 * Plan 2.7: the phone waits for the parent's Allow. These pin what each server answer means and that
 * the poll loop stops on the first decision; `services/api/test/pairing.test.ts` pins the server side.
 */
class PairingApprovalTest {

    /** Feeds [answers] to the loop one poll at a time and records every sleep. */
    private fun run(vararg answers: Any, maxPolls: Int = PairingApproval.MAX_POLLS): Pair<PairingApproval.PollStep, List<Long>> {
        val queue = ArrayDeque(answers.toList())
        val sleeps = mutableListOf<Long>()
        val step = runBlocking {
            PairingApproval.awaitDecision(
                poll = {
                    when (val next = queue.removeFirstOrNull() ?: 202) {
                        is IOException -> throw next
                        else -> next as Int
                    }
                },
                sleep = { sleeps += it },
                maxPolls = maxPolls,
            )
        }
        return step to sleeps
    }

    @Test
    fun `the claim answers map to what the screen shows`() {
        assertEquals(PairingApproval.ClaimStep.WAITING_FOR_PARENT, PairingApproval.claimStep(202))
        assertEquals(PairingApproval.ClaimStep.INVALID_CODE, PairingApproval.claimStep(404))
        assertEquals(PairingApproval.ClaimStep.ALREADY_CLAIMED, PairingApproval.claimStep(409))
        assertEquals(PairingApproval.ClaimStep.CONSENT_REQUIRED, PairingApproval.claimStep(428))
        // The old flow's 201 from the claim itself is not a pairing any more.
        assertEquals(PairingApproval.ClaimStep.FAILED, PairingApproval.claimStep(201))
    }

    @Test
    fun `polls every two seconds until the parent allows`() {
        val (step, sleeps) = run(202, 202, 201)
        assertEquals(PairingApproval.PollStep.APPROVED, step)
        assertEquals(listOf(2_000L, 2_000L), sleeps)
    }

    @Test
    fun `a Deny ends the wait at once`() {
        val (step, sleeps) = run(202, 410, 201)
        assertEquals(PairingApproval.PollStep.DENIED, step)
        assertEquals(1, sleeps.size)
    }

    @Test
    fun `an expired or unknown claim ends the wait`() {
        assertEquals(PairingApproval.PollStep.EXPIRED, run(404).first)
        assertEquals(PairingApproval.PollStep.CONSENT_REQUIRED, run(202, 428).first)
        assertEquals(PairingApproval.PollStep.FAILED, run(500).first)
    }

    @Test
    fun `a network error is a missed poll, not an answer`() {
        val (step, sleeps) = run(IOException("offline"), IOException("offline"), 201)
        assertEquals(PairingApproval.PollStep.APPROVED, step)
        assertEquals(2, sleeps.size)
    }

    @Test
    fun `the loop gives up after its bound if the server never decides`() {
        val (step, sleeps) = run(maxPolls = 5)
        assertEquals(PairingApproval.PollStep.TIMED_OUT, step)
        assertEquals(4, sleeps.size)
    }

    @Test
    fun `release builds pair only with https on osratech dot com`() {
        assertTrue(PairingApproval.isReleasePairingHost("https://api.osratech.com"))
        assertTrue(PairingApproval.isReleasePairingHost("https://API.OsraTech.com/v1"))
        assertTrue(PairingApproval.isReleasePairingHost("https://osratech.com"))
        assertFalse(PairingApproval.isReleasePairingHost("http://api.osratech.com"))
        assertFalse(PairingApproval.isReleasePairingHost("https://osratech.com.example.net"))
        assertFalse(PairingApproval.isReleasePairingHost("https://evilosratech.com"))
        assertFalse(PairingApproval.isReleasePairingHost("https://user@api.osratech.com"))
        assertFalse(PairingApproval.isReleasePairingHost("https://192.168.1.5:3000"))
        assertFalse(PairingApproval.isReleasePairingHost("not a url"))
    }

    @Test
    fun `a release scan refuses a QR code for another server, a debug scan keeps it`() {
        val lan = "osra://pair?v=1&code=482916&host=http%3A%2F%2F192.168.1.5%3A3000"
        val ours = "osra://pair?v=1&code=482916&host=https%3A%2F%2Fapi.osratech.com"
        assertEquals("http://192.168.1.5:3000", PairQrPayload.decode(lan).apiBaseUrl)
        val refused = assertThrows(PairQrFormatException::class.java) { PairQrPayload.decode(lan, releaseHostsOnly = true) }
        assertTrue(refused.message.orEmpty().contains("not OSRA's"))
        assertEquals("https://api.osratech.com", PairQrPayload.decode(ours, releaseHostsOnly = true).apiBaseUrl)

        val flow = PairingScanFlow(releaseHostsOnly = true)
        assertTrue(flow.scan(lan) is PairingScanFlow.State.Rejected)
        assertTrue(flow.scan(ours) is PairingScanFlow.State.Review)
    }
}
