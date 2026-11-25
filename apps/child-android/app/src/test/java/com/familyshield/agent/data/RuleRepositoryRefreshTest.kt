package com.familyshield.agent.data

import com.familyshield.agent.enforcement.PackageFacts
import com.familyshield.agent.network.ApiService
import com.familyshield.agent.network.dto.RuleSetDto
import com.squareup.moshi.Moshi
import com.squareup.moshi.kotlin.reflect.KotlinJsonAdapterFactory
import java.io.IOException
import java.util.concurrent.atomic.AtomicInteger
import java.util.concurrent.atomic.AtomicReference
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertNull
import org.junit.Assert.assertSame
import org.junit.Test
import org.mockito.Mockito

class RuleRepositoryRefreshTest {

    @Test
    fun `a failed rules save returns null then a retry succeeds only after persistence`() = runBlocking {
        // #1151 review mutant: returning the fetched DTO after saveRulesJson throws makes the
        // worker report success even though no durable rules exist for the next process start.
        val api = Mockito.mock(ApiService::class.java)
        val settings = Mockito.mock(AgentSettings::class.java)
        val blocklist = Mockito.mock(BlocklistStore::class.java)
        val consent = Mockito.mock(ConsentState::class.java)
        val packageFacts = Mockito.mock(PackageFacts::class.java)
        val childId = AtomicReference<String?>(null)
        val writes = AtomicInteger(0)
        val updated = RuleSetDto(rulesVersion = 7)
        Mockito.`when`(settings.childId()).thenAnswer { childId.get() }
        Mockito.`when`(settings.rulesJson()).thenReturn(null)
        Mockito.`when`(api.getRules("child-1")).thenReturn(updated)
        Mockito.`when`(settings.saveRulesJson(Mockito.anyString())).thenAnswer {
            if (writes.incrementAndGet() == 1) throw IOException("synthetic disk-full") else Unit
        }
        val moshi = Moshi.Builder().addLast(KotlinJsonAdapterFactory()).build()
        val repository = RuleRepository(api, settings, moshi, blocklist, null, consent, packageFacts)
        // Let the init coroutine finish its intentional no-child path before the two explicit retries.
        kotlinx.coroutines.delay(100)
        childId.set("child-1")

        assertNull(repository.refresh())
        assertNull(repository.cachedRules())
        assertSame(updated, repository.refresh())
        assertSame(updated, repository.cachedRules())
        Mockito.verify(settings, Mockito.times(2)).saveRulesJson(Mockito.anyString())
        Mockito.verify(settings, Mockito.times(1)).saveAppliedRulesVersion(7)
    }
}
