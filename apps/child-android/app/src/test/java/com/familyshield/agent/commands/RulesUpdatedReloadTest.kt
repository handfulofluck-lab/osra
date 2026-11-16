package com.familyshield.agent

import com.familyshield.agent.commands.CommandDispatcher
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File

/**
 * Issue #826: a parent's web-filter change acked `rules_updated`, but the running `FilterVpnService`
 * kept its old config for 10+ minutes — only a pause/resume cycle applied it. The command path
 * refreshed the store and never reloaded the filter.
 *
 * The effect on a real tunnel is device evidence, not JVM evidence. What the JVM suite can hold is the
 * ordering (refresh first, so the reload reads the new set), that a failed refresh still reloads, and
 * that the command path actually calls both — the last is what was missing.
 */
class RulesUpdatedReloadTest {

    @Test
    fun `the reload runs after the refresh, so the filter reads the new set`() = runBlocking {
        val order = mutableListOf<String>()
        CommandDispatcher.refreshThenReload(
            refresh = { order += "refresh" },
            reload = { order += "reload" },
        )
        assertEquals(listOf("refresh", "reload"), order)
    }

    @Test
    fun `a refresh that throws still reloads from the cached set`() = runBlocking {
        var reloaded = false
        CommandDispatcher.refreshThenReload(
            refresh = { throw IllegalStateException("offline") },
            reload = { reloaded = true },
        )
        assertTrue("the filter must still be told to reload", reloaded)
    }

    @Test
    fun `a reload that throws does not undo the refresh`() = runBlocking {
        var refreshed = false
        CommandDispatcher.refreshThenReload(
            refresh = { refreshed = true },
            reload = { throw IllegalStateException("service not running") },
        )
        assertTrue(refreshed)
    }

    @Test
    fun `the rules_updated branch calls both, and calls the service reload`() {
        val source = source("apps/child-android/app/src/main/java/com/familyshield/agent/commands/CommandDispatcher.kt")
        val branch = source.substringAfter("\"rules_updated\" ->").substringBefore("\"locate_now\" ->")
        assertTrue("the branch must refresh", branch.contains("rules.refresh()"))
        assertTrue("the branch must reload the running filter", branch.contains("FilterVpnService.reload(context)"))
        assertTrue("the two must be ordered by the helper", branch.contains("refreshThenReload("))
    }

    private fun source(relative: String): String {
        var dir: File? = File(System.getProperty("user.dir") ?: ".").absoluteFile
        while (dir != null) {
            val candidate = File(dir, relative)
            if (candidate.isFile) return candidate.readText()
            dir = dir.parentFile
        }
        throw AssertionError("not found from ${System.getProperty("user.dir")}: $relative")
    }
}
