package com.familyshield.agent.vpn

import java.io.File
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class FilterLossWiringTest {
    private val service = sourceFile("FilterVpnService.kt")
    private val state = sourceFile("VpnState.kt")

    @Test
    fun `the revoke handler records loss before queuing the existing alert`() {
        val revoke = service.substringAfter("override fun onRevoke()").substringBefore("override fun onDestroy()")
        // Mutant: move enqueue out of the if, so an ineligible or duplicate callback sends an alert.
        assertTrue(
            Regex(
                """if \(VpnState\.recordFilterLoss\(this, settings, consent, hadEstablishedTunnel\)\) \{\s+""" +
                    """TamperAlertWorker\.enqueue\(this, TamperAlertWorker\.TYPE_VPN_REVOKED\)""",
            ).containsMatchIn(revoke),
        )
    }

    @Test
    fun `only a successful restart or explicit stop clears loss in the VPN service`() {
        val open = service.substringAfter("private fun openTunnel()").substringBefore("private fun stopTunnel()")
        val failed = open.substringAfter("if (fd == null)").substringBefore("tun = fd")
        val successful = open.substringAfter("tun = fd")
        val destruction = service.substringAfter("override fun onDestroy()").substringBefore("private val scope")
        val stopTunnel = service.substringAfter("private fun stopTunnel()").substringBefore("private fun pumpLoop(")
        val explicitStop = service.substringAfter("ACTION_STOP ->").substringBefore("ACTION_RELOAD ->")
        val stopCaller = service.substringAfter("fun stop(context: Context)")
        // Mutants: clear in the descriptor-null branch, or move the clear into ordinary tunnel shutdown.
        assertTrue(failed.contains("return"))
        assertFalse(failed.contains("clearFilterLoss"))
        assertTrue(successful.contains("VpnState.clearFilterLoss(this)"))
        assertFalse(destruction.contains("clearFilterLoss"))
        assertFalse(stopTunnel.contains("clearFilterLoss"))
        assertTrue(explicitStop.contains("VpnState.clearFilterLoss(this)"))
        assertTrue(stopCaller.substringBefore("if (!isRunning)").contains("VpnState.clearFilterLoss(context)"))
    }

    @Test
    fun `the incident is committed before sending the package scoped change signal`() {
        val record = state.substringAfter("internal fun recordFilterLoss(").substringBefore("fun clearFilterLoss(")
        // Mutants: use an asynchronous write here, or remove setPackage from the broadcast.
        assertTrue(record.substringBefore("notifyFilterLossChanged(context)").contains(".commit()"))
        assertTrue(state.contains("Intent(ACTION_FILTER_LOSS_CHANGED).setPackage(context.packageName)"))
    }

    private fun sourceFile(name: String): String {
        val relative = "app/src/main/java/com/familyshield/agent/vpn/$name"
        return generateSequence(File(requireNotNull(System.getProperty("user.dir")))) { it.parentFile }
            .map { File(it, relative) }
            .firstOrNull(File::isFile)
            ?.readText() ?: error("Could not find $relative")
    }
}
