package com.familyshield.agent

import com.familyshield.agent.data.AgentSettings
import com.familyshield.agent.data.BlocklistStore
import com.familyshield.agent.data.ConsentState
import com.familyshield.agent.data.RuleRepository
import com.familyshield.agent.enforcement.PackageFacts
import com.familyshield.agent.network.ApiService
import com.familyshield.agent.network.dto.RuleSetDto
import com.squareup.moshi.Moshi
import com.squareup.moshi.kotlin.reflect.KotlinJsonAdapterFactory
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import org.mockito.Mockito

/**
 * Issue #1024 (Option A): pins the current `socialMonitoring.<app>` missing-key contract on the
 * Android child without changing product defaults:
 * - Unsynced cache (`cached == null`) or absent key in `socialMonitoring` -> enabled (`true`).
 * - Explicit `false` -> disabled (`false`), while sibling absent keys remain enabled (`true`).
 * - Explicit `true` -> enabled (`true`).
 */
class SocialMonitoringRuleContractTest {

    private val moshi: Moshi = Moshi.Builder().addLast(KotlinJsonAdapterFactory()).build()
    private val sharedApps = listOf("whatsapp", "instagram", "tiktok", "snapchat", "discord", "roblox", "line")

    private fun repositoryWithRulesJson(json: String?): RuleRepository {
        val settings = Mockito.mock(AgentSettings::class.java)
        runBlocking { Mockito.`when`(settings.rulesJson()).thenReturn(json) }
        return RuleRepository(
            api = Mockito.mock(ApiService::class.java),
            settings = settings,
            moshi = moshi,
            blocklist = Mockito.mock(BlocklistStore::class.java),
            usageDao = null,
            consent = Mockito.mock(ConsentState::class.java),
            packageFacts = Mockito.mock(PackageFacts::class.java),
        )
    }

    @Test
    fun `missing key and unsynced cache default socialMonitoringEnabled to true`() = runBlocking {
        val unsynced = repositoryWithRulesJson(null)
        for (app in sharedApps) {
            assertTrue("unsynced cache should treat $app as ON", unsynced.socialMonitoringEnabled(app))
        }

        val emptyMapRepo = repositoryWithRulesJson("""{"socialMonitoring":{}}""")
        val loadedEmpty = emptyMapRepo.currentRules()
        assertEquals(emptyMap<String, Boolean>(), loadedEmpty?.socialMonitoring)
        for (app in sharedApps) {
            assertTrue("empty socialMonitoring map should treat $app as ON", emptyMapRepo.socialMonitoringEnabled(app))
        }

        val omittedFieldRepo = repositoryWithRulesJson("""{}""")
        val loadedOmitted = omittedFieldRepo.currentRules()
        assertEquals(emptyMap<String, Boolean>(), loadedOmitted?.socialMonitoring)
        assertEquals(emptyMap<String, Boolean>(), RuleSetDto().socialMonitoring)
        for (app in sharedApps) {
            assertTrue("omitted socialMonitoring field should treat $app as ON", omittedFieldRepo.socialMonitoringEnabled(app))
        }
    }

    @Test
    fun `explicit false disables only that app while explicit true and absent siblings stay enabled`() = runBlocking {
        val repo = repositoryWithRulesJson("""{"socialMonitoring":{"whatsapp":false,"tiktok":true}}""")
        repo.currentRules()

        assertFalse("explicit false must disable whatsapp", repo.socialMonitoringEnabled("whatsapp"))
        assertTrue("explicit true must keep tiktok enabled", repo.socialMonitoringEnabled("tiktok"))
        assertTrue("absent sibling instagram must remain enabled", repo.socialMonitoringEnabled("instagram"))
        assertTrue("absent sibling discord must remain enabled", repo.socialMonitoringEnabled("discord"))
    }
}
