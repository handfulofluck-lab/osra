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
 * Issue #848 (Kimi): the reload must not start a filter that is not running, and a failed step must be
 * reported rather than swallowed. The effect on a real tunnel is device evidence, not JVM evidence.
 */
class RulesUpdatedReloadTest {

    @Test
    fun `the reload runs after the refresh, so the filter reads the new set`() = runBlocking {
        val order = mutableListOf<String>()
        val failed = CommandDispatcher.refreshThenReload(
            refresh = { order += "refresh" },
            reload = { order += "reload" },
        )
        assertEquals(listOf("refresh", "reload"), order)
        assertEquals(emptyList<String>(), failed)
    }

    @Test
    fun `a refresh that throws still reloads from the cached set and is reported`() = runBlocking {
        var reloaded = false
        val failed = CommandDispatcher.refreshThenReload(
            refresh = { throw IllegalStateException("offline") },
            reload = { reloaded = true },
        )
        assertTrue("the filter must still be told to reload", reloaded)
        assertEquals(listOf("refresh"), failed)
    }

    @Test
    fun `a reload that throws does not undo the refresh and is reported`() = runBlocking {
        var refreshed = false
        val failed = CommandDispatcher.refreshThenReload(
            refresh = { refreshed = true },
            reload = { throw IllegalStateException("service not running") },
        )
        assertTrue(refreshed)
        assertEquals(listOf("reload"), failed)
    }

    @Test
    fun `the rules_updated branch reloads without starting a stopped filter`() {
        val source = source("apps/child-android/app/src/main/java/com/familyshield/agent/commands/CommandDispatcher.kt")
        val branch = source.substringAfter("\"rules_updated\" ->").substringBefore("\"locate_now\" ->")
        assertTrue("the branch must refresh", branch.contains("rules.refresh()"))
        assertTrue(
            "the branch must reload the running filter without starting it",
            branch.contains("FilterVpnService.reload(context, startIfStopped = false)"),
        )
        assertTrue("the two must be ordered by the helper", branch.contains("refreshThenReload("))
        assertTrue("a failed step must be logged", branch.contains("Log.w(TAG"))
    }

    @Test
    fun `reload's start-if-stopped is opt-in, so a rule edit cannot revive the filter`() {
        val vpn = source("apps/child-android/app/src/main/java/com/familyshield/agent/vpn/FilterVpnService.kt")
        assertTrue(vpn.contains("fun reload(context: Context, startIfStopped: Boolean = true)"))
        assertTrue(vpn.contains("if (!isRunning) { if (startIfStopped) start(context); return }"))
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
