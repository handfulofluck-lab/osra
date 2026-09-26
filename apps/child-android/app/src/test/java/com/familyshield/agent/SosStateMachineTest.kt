package com.familyshield.agent

import com.familyshield.agent.sos.SosStateMachine
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/** Pure-JVM tests for the Feature #14 SOS countdown state machine (elapsed-ms driven). */
class SosStateMachineTest {

    private val countdownMs = 5_000L

    @Test
    fun `starts idle`() {
        assertTrue(SosStateMachine(countdownMs).state is SosStateMachine.State.Idle)
    }

    @Test
    fun `start begins counting with full remaining`() {
        val machine = SosStateMachine(countdownMs)
        val state = machine.start(nowMs = 100L)
        assertEquals(SosStateMachine.State.Counting(startedAtMs = 100L, remainingMs = countdownMs), state)
    }

    @Test
    fun `tick before deadline stays counting with reduced remaining`() {
        val machine = SosStateMachine(countdownMs)
        machine.start(nowMs = 100L)
        val state = machine.tick(nowMs = 100L + 2_000L)
        assertEquals(SosStateMachine.State.Counting(startedAtMs = 100L, remainingMs = 3_000L), state)
    }

    @Test
    fun `tick at deadline fires`() {
        val machine = SosStateMachine(countdownMs)
        machine.start(nowMs = 100L)
        val state = machine.tick(nowMs = 100L + countdownMs)
        assertTrue(state is SosStateMachine.State.Fired)
    }

    @Test
    fun `tick past deadline fires and stays fired`() {
        val machine = SosStateMachine(countdownMs)
        machine.start(nowMs = 100L)
        machine.tick(nowMs = 100L + countdownMs + 60_000L)
        assertTrue(machine.tick(nowMs = 100L + countdownMs + 120_000L) is SosStateMachine.State.Fired)
    }

    @Test
    fun `cancel during counting moves to cancelled`() {
        val machine = SosStateMachine(countdownMs)
        machine.start(nowMs = 100L)
        machine.tick(nowMs = 1_000L)
        val state = machine.cancel()
        assertTrue(state is SosStateMachine.State.Cancelled)
    }

    @Test
    fun `cancelled countdown can be re-armed`() {
        val machine = SosStateMachine(countdownMs)
        machine.start(nowMs = 100L)
        machine.cancel()
        val state = machine.start(nowMs = 200L)
        assertEquals(SosStateMachine.State.Counting(startedAtMs = 200L, remainingMs = countdownMs), state)
    }

    @Test
    fun `cancel while idle is a no-op`() {
        val machine = SosStateMachine(countdownMs)
        assertTrue(machine.cancel() is SosStateMachine.State.Idle)
    }

    @Test
    fun `tick while idle is a no-op`() {
        val machine = SosStateMachine(countdownMs)
        assertTrue(machine.tick(nowMs = 999L) is SosStateMachine.State.Idle)
    }

    @Test
    fun `start while counting is a no-op keeping original start`() {
        val machine = SosStateMachine(countdownMs)
        machine.start(nowMs = 100L)
        val state = machine.start(nowMs = 999L)
        assertEquals(SosStateMachine.State.Counting(startedAtMs = 100L, remainingMs = countdownMs), state)
    }

    @Test
    fun `start after fired is a no-op`() {
        val machine = SosStateMachine(countdownMs)
        machine.start(nowMs = 100L)
        machine.tick(nowMs = 100L + countdownMs)
        assertTrue(machine.start(nowMs = 999L) is SosStateMachine.State.Fired)
    }

    @Test
    fun `reset returns to idle and allows a new countdown`() {
        val machine = SosStateMachine(countdownMs)
        machine.start(nowMs = 100L)
        machine.tick(nowMs = 100L + countdownMs)
        assertTrue(machine.reset() is SosStateMachine.State.Idle)
        val state = machine.start(nowMs = 500L)
        assertEquals(SosStateMachine.State.Counting(startedAtMs = 500L, remainingMs = countdownMs), state)
    }

    @Test
    fun `remaining never goes negative before firing`() {
        val machine = SosStateMachine(countdownMs)
        machine.start(nowMs = 0L)
        val state = machine.tick(nowMs = countdownMs - 1)
        assertEquals(1L, (state as SosStateMachine.State.Counting).remainingMs)
    }
}
