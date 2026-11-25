package com.familyshield.agent

import com.familyshield.agent.data.AgentSettings
import com.familyshield.agent.data.BlocklistStore
import com.familyshield.agent.data.ConsentState
import com.familyshield.agent.data.RuleRepository
import com.familyshield.agent.enforcement.PackageFacts
import com.familyshield.agent.network.ApiService
import com.familyshield.agent.social.MonitoredApps
import com.squareup.moshi.Moshi
import com.squareup.moshi.kotlin.reflect.KotlinJsonAdapterFactory
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import org.mockito.Mockito

/**
 * Issue #1036: X / Twitter socialMonitoring key contract on the Android child.
 * - Canonical `"twitter"` written by the Parent app disables/enables both `com.twitter.android` and `com.x.android`.
 * - Legacy `"x"` saved by older Parent builds is honoured when `"twitter"` is absent.
 * - Canonical `"twitter"` wins over a stale legacy `"x"` when both are present.
 */
class TwitterSocialMonitoringKeyTest {

    private val moshi: Moshi = Moshi.Builder().addLast(KotlinJsonAdapterFactory()).build()

    private fun repoWith(json: String?): RuleRepository {
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
    fun `parent saving twitter false stops monitoring for com twitter and com x`() = runBlocking {
        val repo = repoWith("""{"socialMonitoring":{"twitter":false}}""")
        repo.currentRules()
        for (pkg in listOf("com.twitter.android", "com.x.android")) {
            val key = MonitoredApps.appKeyFor(pkg)!!
            assertEquals("twitter", key)
            assertFalse("Parent OFF for twitter must disable $pkg", repo.socialMonitoringEnabled(key))
        }
    }

    @Test
    fun `legacy x key is honoured when twitter is absent`() = runBlocking {
        val offRepo = repoWith("""{"socialMonitoring":{"x":false}}""")
        offRepo.currentRules()
        assertFalse("legacy {\"x\": false} must disable twitter", offRepo.socialMonitoringEnabled("twitter"))
        assertTrue("unrelated app must remain enabled", offRepo.socialMonitoringEnabled("whatsapp"))

        val onRepo = repoWith("""{"socialMonitoring":{"x":true}}""")
        onRepo.currentRules()
        assertTrue("legacy {\"x\": true} keeps twitter enabled", onRepo.socialMonitoringEnabled("twitter"))
    }

    @Test
    fun `canonical twitter takes precedence over stale legacy x`() = runBlocking {
        val onWins = repoWith("""{"socialMonitoring":{"twitter":true,"x":false}}""")
        onWins.currentRules()
        assertTrue("canonical twitter=true must beat stale x=false", onWins.socialMonitoringEnabled("twitter"))

        val offWins = repoWith("""{"socialMonitoring":{"twitter":false,"x":true}}""")
        offWins.currentRules()
        assertFalse("canonical twitter=false must beat stale x=true", offWins.socialMonitoringEnabled("twitter"))
    }
}
