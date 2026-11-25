package com.familyshield.agent.services

import java.io.File
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Issue #864 (B6 on the Flip4): a domain rule added from the parent did not reach the filter until the phone
 * restarted. The reload machinery was fine — `RulesSyncWorker` reloads the VPN — but nothing asked for the rules:
 * `RulesSyncWorker` is a six-hour periodic job and `syncNow()` had exactly one caller, `PairingActivity`, right
 * after pairing.
 *
 * **Why a source-text row.** This is wiring inside a `FirebaseMessagingService`, which cannot run on the JVM.
 * The shape follows `FilterVpnBypassWiringTest`: assert the call inside the handler body, not the class.
 *
 * Mutants: removing the `WorkScheduler.syncNow` call, or moving it outside `onMessageReceived`, both leave every
 * other row green while the phone goes back to waiting six hours.
 */
class RulesReachOnPushWiringTest {

    private val service = sourceFile("app/src/main/java/com/familyshield/agent/services/FirebaseMessagingSvc.kt")
    private val handler = service.substringAfter("override fun onMessageReceived(").substringBefore("override fun onNewToken(")

    @Test
    fun `a push asks for the rules as well as the commands`() {
        assertTrue(
            "onMessageReceived must ask for a rules sync; the poll alone only fetches commands",
            handler.contains("WorkScheduler.syncNow(applicationContext)"),
        )
    }

    @Test
    fun `the rules sync stays outside the wake budget`() {
        // The 8 s wake budget is for the command poll. A rules fetch inside it would be cut off by the fallback
        // and leave the phone waiting for the six-hour tick anyway.
        val wake = handler.substringBefore("WorkScheduler.syncNow(applicationContext)")
        assertTrue(wake.contains("PushWakeHandler.onPushReceived("))
    }
}

/** Walks up from the test's working directory, the way the other wiring tests resolve their source. */
private fun sourceFile(relative: String): String {
    var dir: File? = File(System.getProperty("user.dir")).absoluteFile
    while (dir != null) {
        val candidate = File(dir, relative)
        if (candidate.isFile) return candidate.readText()
        dir = dir.parentFile
    }
    throw AssertionError("could not find $relative from ${System.getProperty("user.dir")}")
}
