package com.familyshield.agent.setup

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Roadmap 3.2's safety property, proved without Android: a scan fills a review, and **only** an
 * explicit [PairingScanFlow.confirm] turns that review into a [PairingRequest]. The confirm step is
 * plain state — no camera callback — so it is reachable when the camera is denied or absent.
 */
class PairingScanFlowTest {

    private val valid = "osra://pair?v=1&code=482916&host=http%3A%2F%2F192.168.1.5%3A3000"

    @Test
    fun `a valid scan moves to review and builds no request`() {
        val flow = PairingScanFlow()
        val state = flow.scan(valid)
        assertTrue(state is PairingScanFlow.State.Review)
        assertEquals(
            "http://192.168.1.5:3000",
            (state as PairingScanFlow.State.Review).payload.apiBaseUrl,
        )
        assertEquals("482916", state.payload.code)
    }

    @Test
    fun `confirm builds the pairing request from the scanned values`() {
        val flow = PairingScanFlow()
        flow.scan(valid)
        val request = flow.confirm(deviceName = "  Alex's phone  ")
        assertEquals(
            PairingRequest(
                serverUrl = "http://192.168.1.5:3000",
                code = "482916",
                deviceName = "Alex's phone",
            ),
            request,
        )
    }

    @Test
    fun `confirm before any scan returns null`() {
        assertNull(PairingScanFlow().confirm(deviceName = "phone"))
    }

    @Test
    fun `a rejected scan explains why and cannot be confirmed`() {
        val flow = PairingScanFlow()
        val state = flow.scan("osra://pair?v=2&code=482916&host=http%3A%2F%2Fx")
        assertTrue(state is PairingScanFlow.State.Rejected)
        assertTrue((state as PairingScanFlow.State.Rejected).reason.contains("unsupported pairing code version: 2"))
        assertNull(flow.confirm(deviceName = "phone"))
    }

    @Test
    fun `garbage is rejected rather than falling back to a typed code`() {
        val flow = PairingScanFlow()
        flow.scan("not a pairing payload")
        assertTrue(flow.state is PairingScanFlow.State.Rejected)
        assertNull(flow.confirm(deviceName = "phone"))
    }

    @Test
    fun `cancel returns to idle and clears the review`() {
        val flow = PairingScanFlow()
        flow.scan(valid)
        flow.cancel()
        assertTrue(flow.state is PairingScanFlow.State.Idle)
        assertNull(flow.confirm(deviceName = "phone"))
    }

    @Test
    fun `a failed pairing attempt can be confirmed again with the same scanned values`() {
        val flow = PairingScanFlow()
        flow.scan(valid)
        val first = flow.confirm(deviceName = "phone")
        val second = flow.confirm(deviceName = "phone")
        assertEquals(first, second)
    }
}
