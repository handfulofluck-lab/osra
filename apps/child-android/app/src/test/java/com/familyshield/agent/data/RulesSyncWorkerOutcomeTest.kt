package com.familyshield.agent.data

import com.familyshield.agent.network.dto.RuleSetDto
import org.junit.Assert.assertEquals
import org.junit.Test

class RulesSyncWorkerOutcomeTest {

    @Test
    fun `paired empty refresh retries while unpaired empty and persisted refresh succeed`() {
        // Codex #1151 re-review: this distinguishes the actual paired-empty branch from a catch
        // that merely contains the same Result.retry text.
        assertEquals(RulesSyncWorker.Companion.RefreshOutcome.RETRY, RulesSyncWorker.Companion.refreshOutcome(null, isPaired = true))
        assertEquals(RulesSyncWorker.Companion.RefreshOutcome.SUCCESS, RulesSyncWorker.Companion.refreshOutcome(null, isPaired = false))
        assertEquals(RulesSyncWorker.Companion.RefreshOutcome.SUCCESS, RulesSyncWorker.Companion.refreshOutcome(RuleSetDto(), isPaired = true))
    }
}
