package com.familyshield.agent.vpn

import java.io.File
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * #481 review: [TunnelBypassPolicyTest] pins *who* is excluded, but not that `FilterVpnService` asks
 * for the pause list in pause mode, or applies it at all. Inverting the mode check or ignoring the
 * list both passed every row, and either one brings #458 back on the phone.
 *
 * **Why a source-text row.** `VpnService.Builder` cannot be built on the JVM, so the shape follows
 * `UnlinkedRefreshWiringTest`: assert the wiring inside the `openTunnel` body itself.
 *
 * Mutants: `sinkholeAll = mode != MODE_SINKHOLE_ALL` → [openTunnel asks the policy for the pause list
 * exactly in pause mode]; exclude a hand-built list instead of `bypass` → [openTunnel applies that list
 * and nothing else].
 */
class FilterVpnBypassWiringTest {

    private val service = sourceFile("app/src/main/java/com/familyshield/agent/vpn/FilterVpnService.kt")
    private val openTunnel = service.substringAfter("private fun openTunnel()").substringBefore("private fun stopTunnel()")

    @Test
    fun `openTunnel asks the policy for the pause list exactly in pause mode`() {
        assertTrue(openTunnel.contains("TunnelBypassPolicy.excludedPackages("))
        assertTrue(
            "the pause list (with gms) belongs to pause mode only",
            openTunnel.contains("sinkholeAll = mode == MODE_SINKHOLE_ALL,"),
        )
    }

    @Test
    fun `openTunnel applies that list and nothing else`() {
        assertTrue(openTunnel.contains("for (pkg in bypass) runCatching { builder.addDisallowedApplication(pkg) }"))
        assertEquals(
            "one exclusion site, so the policy is the whole list",
            1,
            openTunnel.split("addDisallowedApplication(").size - 1,
        )
        assertTrue(
            "applied before the tunnel is established",
            openTunnel.indexOf("for (pkg in bypass)") < openTunnel.indexOf("builder.establish()"),
        )
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
