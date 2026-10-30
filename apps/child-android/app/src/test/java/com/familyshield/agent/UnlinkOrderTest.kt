package com.familyshield.agent

import com.familyshield.agent.data.RuleRepository
import com.familyshield.agent.network.DeviceRevoked
import com.familyshield.agent.network.UnlinkPolicy
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Issue #465 review: three rows for the three findings that changed the code.
 *
 * The first two are the **order** finding. `RuleRepository.decide` fails closed when the phone is paired
 * and no rules are cached (AND-03), which is the right default for a phone whose rules have not arrived
 * yet — and the worst possible state to strand a deleted family's phone in. Forgetting the rules before
 * clearing the pairing left exactly that window, and a throw from `clearPairing()` would have made it
 * permanent: every app blocked, no parent to fix it.
 */
class UnlinkOrderTest {

    private fun decide(packageId: String, rules: com.familyshield.agent.network.dto.RuleSetDto?, paired: Boolean) =
        RuleRepository.decide(
            packageId = packageId,
            ruleSet = rules,
            paired = paired,
            consentPaused = false,
            essential = { false },
            rulesDecision = { RuleRepository.Decision.BLOCK },
        )

    @Test
    fun `after the unlink an ordinary app is allowed, which is why the pairing goes first`() {
        // The state `DeviceUnlinker` now reaches: pairing cleared, rules gone. Nothing enforces.
        assertEquals(RuleRepository.Decision.ALLOW, decide("com.example.game", null, paired = false))
    }

    @Test
    fun `paired with no rules would block every app, which is the state the order avoids`() {
        // The state the old order could strand: still paired, rules already forgotten.
        // Mutant: swap `clearPairing()` and `forgetRules()` back and a throw from the first leaves the
        // phone here permanently — every non-essential app blocked, with no parent to reverse it.
        assertEquals(RuleRepository.Decision.BLOCK, decide("com.example.game", null, paired = true))
    }

    @Test
    fun `the shared answer path stops the poll only for a confirmed revocation`() {
        // The composition `CommandPoller.onPollAnswer` performs, in the order it performs it. The wiring
        // itself (a Service and a Worker) is not JVM-reachable; this pins the decision, and Claude's
        // `LocationService skips the shared call` fault is what proves the wiring.
        val policy = UnlinkPolicy()
        assertEquals("a plain 401 is not a revocation", false, DeviceRevoked.isRevoked(401, null))
        assertTrue(DeviceRevoked.isRevoked(401, DeviceRevoked.codeFromBody("""{"error":"device_revoked"}""")))
        assertFalse("one answer does not stop the poll", policy.onDeviceRevoked(0L))
        assertTrue("the second, a minute later, does", policy.onDeviceRevoked(60_000L))
        assertFalse(policy.shouldPoll())
    }
}
