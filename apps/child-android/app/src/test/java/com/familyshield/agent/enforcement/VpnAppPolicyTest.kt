package com.familyshield.agent.enforcement

import com.familyshield.agent.data.RuleEngine
import com.familyshield.agent.data.RuleRepository.Decision
import com.familyshield.agent.data.WindowKind
import com.familyshield.agent.network.dto.AppRuleDto
import com.familyshield.agent.network.dto.RoutineDto
import com.familyshield.agent.network.dto.RuleSetDto
import java.time.ZonedDateTime
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class VpnAppPolicyTest {

    private val ownPackage = "com.example.agent"
    private val candidate = "com.example.candidate"
    private val bindingPermission = "android.permission.BIND_VPN_SERVICE"
    private val noon = ZonedDateTime.parse("2026-11-16T12:00Z") // Monday, outside bedtime.
    private val engine = RuleEngine()

    @Test
    fun `only a service with the exact VPN binding permission classifies the package`() {
        // Mutants: matching a permission prefix or checking only the first service.
        assertFalse(classify(sequenceOf(null, "android.permission.BIND_VPN_SERVICE_EXTRA")))
        assertTrue(classify(sequenceOf(null, bindingPermission)))
    }

    @Test
    fun `the agent is excluded before its services are read`() {
        // Mutant: dropping the installed application identity check.
        assertFalse(packageDeclaresVpnService(ownPackage, ownPackage) { error("OSRA is exempt") })
    }

    @Test
    fun `a new installation is denied on the next app verdict without a rule sync`() {
        // Mutants: caching a negative classification or removing its default block from the rule engine.
        val installed = mutableMapOf<String, List<String?>>()
        val rules = RuleSetDto()
        fun decision() = engine.evaluate(rules, candidate, noon, declaresVpnService = {
            packageDeclaresVpnService(candidate, ownPackage) { installed[it].orEmpty().asSequence() }
        })

        assertEquals(Decision.ALLOW, decision())
        installed[candidate] = listOf(bindingPermission)
        assertEquals(Decision.BLOCK, decision())
        installed.remove(candidate)
        assertEquals(Decision.ALLOW, decision())
    }

    @Test
    fun `only an explicit per-app or always-allowed exception overrides the VPN default`() {
        // Mutants: testing the default block before an explicit allow, or treating time_limit as approval.
        fun decide(action: String) = engine.evaluate(
            RuleSetDto(appRules = listOf(AppRuleDto(packageId = candidate, action = action, dailyLimitMinutes = 10))),
            candidate,
            noon,
            declaresVpnService = { true },
        )

        assertEquals(Decision.ALLOW, decide("allow"))
        assertEquals(Decision.BLOCK, decide("block"))
        assertEquals(Decision.BLOCK, decide("time_limit"))
        assertEquals(
            Decision.ALLOW,
            engine.evaluate(
                RuleSetDto(alwaysAllowedApps = listOf(candidate)),
                candidate,
                noon,
                declaresVpnService = { true },
            ),
        )
    }

    @Test
    fun `routines still apply before a per-app allow while network-only pause leaves apps open (#1183)`() {
        // Mutant: allowing a VPN exception before checking an active routine.
        val allowed = RuleSetDto(appRules = listOf(AppRuleDto(packageId = candidate, action = "allow")))
        assertEquals(
            Decision.ALLOW,
            engine.evaluate(allowed, candidate, noon, pausedInternet = true, declaresVpnService = { true }),
        )
        val routine = RoutineDto(
            name = "Quiet time",
            startTime = "11:00",
            endTime = "13:00",
            days = listOf(1),
            blockedApps = listOf(candidate),
        )
        val scheduled = allowed.copy(routines = listOf(routine))
        val verdict = engine.evaluateWithReason(scheduled, candidate, noon, declaresVpnService = { true })
        assertEquals(Decision.BLOCK, verdict.decision)
        assertEquals(WindowKind.ROUTINE, verdict.reason?.kind)
    }

    private fun classify(permissions: Sequence<String?>): Boolean =
        packageDeclaresVpnService(candidate, ownPackage) { permissions }
}
