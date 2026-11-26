package com.familyshield.agent.vpn

import java.io.File
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Issue #1079, Hydrogen's #1097 review: the policy and its rows were green while **no `src/main` path ever
 * asked the question**. `CapabilityReporter` built its facts without `webFilter`, and `FilterVpnService`
 * built its config without the pack or the blocked categories, so a phone with no pack still reported
 * `web_filter: ready` and the `UNPROTECTED -> DEGRADED` branch was unreachable outside the unit test.
 *
 * This reads the sources as text, the technique `CapabilityWiringTest` and `LocationServiceStartSitesTest`
 * already use: it proves the two production call sites pass the facts. The semantics are
 * `DnsFilterPolicyTest` and `CapabilitiesPolicyTest`.
 *
 * Mutants, one per assertion: dropping `webFilter = DnsFilterPolicy.enforcement(` from the reporter's
 * `CapabilityFacts`, dropping `packLoaded = blocklist.packStored()` or `blockedCategories =` from either
 * site, and removing `packStored()` from the store.
 */
class WebFilterPackStateWiringTest {

    private val reporter = sourceFile("app/src/main/java/com/familyshield/agent/capabilities/CapabilityReporter.kt")
    private val service = sourceFile("app/src/main/java/com/familyshield/agent/vpn/FilterVpnService.kt")
    private val store = sourceFile("app/src/main/java/com/familyshield/agent/data/BlocklistStore.kt")

    @Test
    fun `the capability report carries the filter's enforcement state`() {
        assertTrue(
            "the reporter must pass webFilter from DnsFilterPolicy.enforcement, or the key keeps its default",
            reporter.contains("webFilter = DnsFilterPolicy.enforcement("),
        )
        assertTrue(
            "and from the store's own facts, not a constant",
            reporter.contains("packStored = blocklist.packStored()") &&
                reporter.contains("categoryDomains = blocklist.domains()"),
        )
        assertTrue(
            "the blocked categories come from the active rule set",
            reporter.contains("blockedCategories = rules.cachedRules()?.webFilter?.blockedCategories ?: emptyList()"),
        )
    }

    @Test
    fun `the tunnel builds its table with the pack and the categories`() {
        val body = functionBody(service, "private fun applyRules(")
        assertTrue("the config carries the pack flag", body.contains("packLoaded = blocklist.packStored()"))
        assertTrue("the config carries the blocked categories", body.contains("blockedCategories = wf?.blockedCategories"))
        assertTrue("and the domains", body.contains("categoryDomains = blocklist.domains()"))
    }

    @Test
    fun `the store exposes whether a pack was stored`() {
        assertTrue(
            "packStored() is the fact both call sites read; without it they would invent their own",
            store.contains("fun packStored(): Boolean"),
        )
        assertTrue("a successful refresh marks it stored", store.contains("cachedPackStored = true"))
    }

    private fun functionBody(source: String, signature: String): String {
        val start = source.indexOf(signature)
        assertTrue("$signature exists", start >= 0)
        val end = source.indexOf("\n    private fun ", start + 1).let { if (it < 0) source.length else it }
        return source.substring(start, end)
    }

    private fun sourceFile(relative: String): String {
        var dir: File? = File(System.getProperty("user.dir")).absoluteFile
        while (dir != null) {
            val candidate = File(dir, relative)
            if (candidate.isFile) return candidate.readText()
            dir = dir.parentFile
        }
        throw AssertionError("could not find $relative from ${System.getProperty("user.dir")}")
    }
}
